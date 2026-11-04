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
      name = "debug";
      min_args = 0;
      max_args = None;
      crosses_host = true;
      doc =
        "Write the arguments the way `print` does, as one line of \
         diagnostic output: standard error where the host has one, the \
         console in a browser. Yields unit, like `print`. A program \
         compiled with `--release` has every call to it removed, \
         arguments and all. Unlike `print`, a call to it will be allowed \
         in a pure function.";
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
      name = "string";
      min_args = 1;
      max_args = Some 1;
      crosses_host = false;
      doc =
        "Answer the argument as a String, formatted the way `print` writes \
         it -- so a Bool is `true`/`false` and unit is `()`, in Pyking's own \
         spelling rather than the host's, and a Char is its one character. \
         Accepts an Int, a Float, a String, a Char, a Bool, a list or a \
         tuple.";
    };
    {
      name = "len";
      min_args = 1;
      max_args = Some 1;
      crosses_host = false;
      doc =
        "Answer how many items a list or an array holds, or how many \
         characters -- Unicode code points, as `s[i]` counts them -- a \
         String holds.";
    };
    {
      name = "same";
      min_args = 2;
      max_args = Some 2;
      crosses_host = false;
      doc =
        "Answer whether two arrays, two DynArrays or two var structs are the \
         same one -- one value under two names, so writing through one is \
         seen through the other -- rather than two holding the same \
         elements or fields, which `array.equal` asks of arrays. `==` \
         compares none of them.";
    };
    {
      name = "push";
      min_args = 2;
      max_args = Some 2;
      crosses_host = false;
      doc =
        "Add a value to the end of a DynArray: `push(v, x)`. Needs `use \
         mutation`.";
    };
    {
      name = "pop";
      min_args = 1;
      max_args = Some 1;
      crosses_host = false;
      doc =
        "Remove a DynArray's last element and answer it: `pop(v)`. Popping an \
         empty DynArray is a runtime error. Needs `use mutation`.";
    };
    {
      name = "insert";
      min_args = 3;
      max_args = Some 3;
      crosses_host = false;
      doc =
        "Put a value into a DynArray before index i, moving the elements from i \
         on one place up: `insert(v, i, x)`, with 0 <= i <= len(v). Needs \
         `use mutation`.";
    };
    {
      name = "remove";
      min_args = 2;
      max_args = Some 2;
      crosses_host = false;
      doc =
        "Take the element at index i out of a DynArray and answer it, moving \
         the ones after it one place down: `remove(v, i)`; or take a key's \
         entry out of a MutMap and answer its value, `remove(d, k)`, which \
         is a runtime error where there is none. Needs `use mutation`.";
    };
    {
      name = "clear";
      min_args = 1;
      max_args = Some 1;
      crosses_host = false;
      doc = "Remove every element of a DynArray, or every entry of a MutMap: `clear(v)`. Needs `use mutation`.";
    };
    {
      name = "view";
      min_args = 3;
      max_args = Some 3;
      crosses_host = false;
      doc =
        "A view of elements i up to j of an array, or of another view: \
         `view(a, i, j)`, with 0 <= i <= j <= len(a). It holds no elements \
         of its own: reading and writing it reads and writes the array. \
         Needs `use mutation`.";
    };
    {
      name = "copy_into";
      min_args = 2;
      max_args = Some 2;
      crosses_host = false;
      doc =
        "Write an array's or a view's elements over the first ones of \
         another: `copy_into(dst, src)`, with len(src) <= len(dst). Where \
         the two share elements it copies as if through a copy of src. \
         Needs `use mutation`.";
    };
    {
      name = "get";
      min_args = 3;
      max_args = Some 3;
      crosses_host = false;
      doc =
        "A MutMap's value for a key, or a default where it has none: `get(d, \
         k, default)`. The default is worked out whether it is needed or \
         not.";
    };
    {
      name = "has";
      min_args = 2;
      max_args = Some 2;
      crosses_host = false;
      doc = "Whether a MutMap has an entry for a key: `has(d, k)`.";
    };
    {
      name = "discard";
      min_args = 2;
      max_args = Some 2;
      crosses_host = false;
      doc =
        "Remove a MutMap's entry for a key, if it has one: `discard(d, k)`. \
         `remove(d, k)` is the form that requires one. Needs `use \
         mutation`.";
    };
    {
      name = "keys";
      min_args = 1;
      max_args = Some 1;
      crosses_host = false;
      doc = "A MutMap's keys, as a list, in the order they were put in: `keys(d)`.";
    };
    {
      name = "values";
      min_args = 1;
      max_args = Some 1;
      crosses_host = false;
      doc = "A MutMap's values, as a list, in the order of their keys: `values(d)`.";
    };
    {
      name = "items";
      min_args = 1;
      max_args = Some 1;
      crosses_host = false;
      doc =
        "A MutMap's entries, as a list of (key, value) pairs, in the order \
         they were put in: `items(d)`.";
    };
    {
      name = "float";
      min_args = 1;
      max_args = Some 1;
      crosses_host = false;
      doc =
        "Answer the argument as a Float: an Int exactly for a magnitude \
         below 2^53 and as the nearest double above it, a Bool as 1.0 or \
         0.0, a Float as itself, a Char as its code point, and a String read \
         by `parse_float` -- NaN where it is not a number. Pyking converts nothing on its own, so \
         this and `int` are the only way an Int and a Float meet.";
    };
    {
      name = "int";
      min_args = 1;
      max_args = Some 1;
      crosses_host = false;
      doc =
        "Answer the argument as an Int: a Float truncated toward zero -- the \
         rounding `/` already does -- a Bool as 1 or 0, an Int as itself, \
         a Char as its code point, and a String read by `parse_int`. Where there is no Int to answer \
         -- a String that is not one, a NaN, an infinity, a value outside \
         the signed 32-bit range -- it is 0.";
    };
    {
      name = "bool";
      min_args = 1;
      max_args = Some 1;
      crosses_host = false;
      doc =
        "Answer the argument as a Bool: true for the String \"true\", the \
         Int 1, the Float 1.0 and every Char but '\\0', a Bool as itself, \
         and false for anything else.";
    };
    {
      name = "char";
      min_args = 1;
      max_args = Some 1;
      crosses_host = false;
      doc =
        "Answer the argument as a Char: the Char whose code point an Int \
         is, the first character of a String, a Char as itself. Where \
         there is none -- an Int that is no code point, an empty String \
         -- it is '\\0'.";
    };
  ]

(** Every builtin's name, in the order the table lists them. [string] *)
let names = List.map (fun builtin -> builtin.name) all

(** The builtin overload sets: a name a program calls unbound, and its
    members, each a `::` definition the checker binds (typesystem.ml's
    `builtin_env`) and resolves a call among by its arguments. After
    elaborate.ml a call names a member's plain name -- `fill__array` --
    and that is what the interpreter and every backend implement.
    `array` makes an array from a list or of one value, and `array_init`
    generates one, from the index or from an accumulator (PYKING.md,
    "Arrays"). Each set's members differ in how many arguments they take.
    [(string, [string])] *)
let overload_sets =
  [
    ("array", [ "list::array"; "fill::array" ]);
    ("array_init", [ "init::array_init"; "unfold::array_init" ]);
    ("dynarray", [ "empty::dynarray"; "list::dynarray" ]);
    ("mutmap", [ "empty::mutmap"; "list::mutmap" ]);
  ]

(** The builtins that change a mutable collection in place, which need
    `use mutation` to call (PYKING.md, "DynArrays", "MutMaps"). [string] *)
let writers = [ "push"; "pop"; "insert"; "remove"; "clear"; "discard"; "view"; "copy_into" ]

(** The builtins younger than the programs and libraries that use the
    name for something of their own -- tinyweb's `push` and `remove`,
    `color.same` -- so a module's own definition or import of the name
    is allowed, and then means itself there. [string] *)
let yielding = [ "same"; "get"; "has"; "keys"; "values"; "items" ] @ writers

(** The plain names the members of the builtin overload sets compile to.
    [string] *)
let member_names =
  List.concat_map (fun (_, members) -> List.map Names.renamed members) overload_sets

(** What a reader sees as builtin words: every builtin and every builtin
    overload set's name, for highlighting and completion. [string] *)
let words = names @ List.map fst overload_sets

(** What a builtin overload set does, for the editor's hover. string ->
    string option *)
let overload_doc name =
  match name with
  | "array" ->
      Some
        "Make an array: `array(xs)` from a list, and `array(n, v)` of n \
         copies of v. `array_init` generates one. Needs `use mutation`."
  | "array_init" ->
      Some
        "Generate an array: `array_init(n, f)` with element i being f(i), \
         and `array_init(n, seed, f)` unfolding an accumulator, f answering \
         each element and the next accumulator. Needs `use mutation`."
  | "mutmap" ->
      Some
        "Make a MutMap, a mutable map from keys to values that remembers the \
         order its keys were put in: `mutmap()` with no entries, and \
         `mutmap(pairs)` from a list of (key, value) pairs. `d[k]` reads, \
         `d[k] := v` writes. Needs `use mutation`."
  | "dynarray" ->
      Some
        "Make a DynArray, an array that grows: `dynarray()` with no elements, and \
         `dynarray(xs)` from a list. `push`, `pop`, `insert`, `remove` and \
         `clear` change it. Needs `use mutation`."
  | _ -> None

(** The builtin a name denotes, or None if it is an ordinary Pyking
    name. string -> t option *)
let lookup name = List.find_opt (fun builtin -> builtin.name = name) all

(** Whether name is `debug`, the builtin whose output is diagnostic
    rather than the program's own. string -> bool *)
let is_debug name = name = "debug"

(* --- what a conversion reads ---

   The rules every target implements for `int`, `float` and `bool` of a
   String, and for `int` of a Float, stated once here and implemented by
   each backend in its own host language: no host's own parser accepts
   the same strings (see docs/builtin.md, "Conversions"). Today a failed
   conversion answers a default; once Pyking has an option type it will
   answer none instead. *)

(** The Int range a conversion answers within: signed 32 bits, the
    range the lexer bounds a literal by. int *)
let int_min = -2147483648

let int_max = 2147483647

(** Whether every character of text from index `from` is a decimal
    digit, and there is at least one. string -> int -> bool *)
let digits_from text from =
  let length = String.length text in
  from < length
  && String.for_all (fun c -> c >= '0' && c <= '9')
       (String.sub text from (length - from))

(** A String as `int` reads it: an optional sign, then decimal digits,
    within the signed 32-bit range -- nothing else, not even a space.
    string -> int option *)
let parse_int text =
  let signed = String.length text > 0 && (text.[0] = '-' || text.[0] = '+') in
  if not (digits_from text (if signed then 1 else 0)) then None
  else
    let negative = signed && text.[0] = '-' in
    (* Accumulated as a negative number, which reaches int_min without
       passing through a value the browser build's 32-bit int cannot
       hold. *)
    let rec go i n =
      if i = String.length text then Some n
      else
        let d = Char.code text.[i] - Char.code '0' in
        if n < int_min / 10 || (n = int_min / 10 && d > -(int_min mod 10)) then None
        else go (i + 1) ((n * 10) - d)
    in
    match go (if signed then 1 else 0) 0 with
    | Some n when negative -> Some n
    | Some n when n >= -int_max -> Some (-n)
    | _ -> None

(** A String as `float` reads it: an optional sign, digits, an optional
    `.` and digits, an optional exponent -- or `inf`, `-inf` or `nan`,
    which is what `print` writes for those. string -> float option *)
let parse_float text =
  match text with
  | "inf" | "+inf" -> Some infinity
  | "-inf" -> Some neg_infinity
  | "nan" -> Some nan
  | _ ->
      let length = String.length text in
      let rec digits i = if i < length && text.[i] >= '0' && text.[i] <= '9' then digits (i + 1) else i in
      let start = if length > 0 && (text.[0] = '-' || text.[0] = '+') then 1 else 0 in
      let whole = digits start in
      if whole = start then None
      else
        let after_fraction =
          if whole < length && text.[whole] = '.' then
            let fraction = digits (whole + 1) in
            if fraction = whole + 1 then None else Some fraction
          else Some whole
        in
        let after_exponent =
          match after_fraction with
          | Some i when i < length && (text.[i] = 'e' || text.[i] = 'E') ->
              let sign = if i + 1 < length && (text.[i + 1] = '-' || text.[i + 1] = '+') then i + 2 else i + 1 in
              let exponent = digits sign in
              if exponent = sign then None else Some exponent
          | found -> found
        in
        match after_exponent with
        | Some i when i = length -> float_of_string_opt text
        | _ -> None

(** A Float as `int` reads it: truncated toward zero, and 0 where that is
    no Int in the signed 32-bit range -- a NaN, an infinity, a value past
    the range. float -> int *)
let truncate_float x =
  if Float.is_nan x then 0
  else
    let t = Float.trunc x in
    if t < float_of_int int_min || t > float_of_int int_max then 0
    else int_of_float t

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

(** A Float as `print` and `string` write it. float -> string *)
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

(* --- characters ---

   A Char is one Unicode code point, and a String is counted in them:
   `len`, `s[i]` and `for c in s` all agree with lib/text. Strings are
   UTF-8 in the compiler, the interpreter and the OCaml and C targets. *)

let is_code_point n = n >= 0 && n <= 0x10FFFF && not (n >= 0xD800 && n <= 0xDFFF)

let code_points s =
  let rec go k acc =
    if k >= String.length s then List.rev acc
    else
      let d = String.get_utf_8_uchar s k in
      go (k + Uchar.utf_decode_length d) (Uchar.to_int (Uchar.utf_decode_uchar d) :: acc)
  in
  go 0 []

let utf8 n =
  let b = Buffer.create 4 in
  Buffer.add_utf_8_uchar b
    (if is_code_point n then Uchar.of_int n else Uchar.of_int 0xFFFD);
  Buffer.contents b

let utf8_length s =
  let rec go k count =
    if k >= String.length s then count
    else go (k + Uchar.utf_decode_length (String.get_utf_8_uchar s k)) (count + 1)
  in
  go 0 0

let char_of_int n = if is_code_point n then n else 0

let char_of_string s = match code_points s with c :: _ -> c | [] -> 0

let quote_char c =
  match c with
  | 0x27 -> "'\\''"
  | 0x5C -> "'\\\\'"
  | 0x0A -> "'\\n'"
  | 0x09 -> "'\\t'"
  | 0x0D -> "'\\r'"
  | 0x00 -> "'\\0'"
  | _ -> "'" ^ utf8 c ^ "'"

let quote_string s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (fun c ->
      Buffer.add_string b
        (match c with
        | '\\' -> "\\\\"
        | '"' -> "\\\""
        | '\n' -> "\\n"
        | '\t' -> "\\t"
        | '\r' -> "\\r"
        | '\000' -> "\\0"
        | c -> String.make 1 c))
    s;
  Buffer.add_char b '"';
  Buffer.contents b

let utf16_length s =
  List.fold_left (fun n c -> n + if c >= 0x10000 then 2 else 1) 0 (code_points s)
