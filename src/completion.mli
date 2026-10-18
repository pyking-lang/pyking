(** What may be written where the cursor is: the parts of completion the
    language server (lsp.ml) and the REPL (repl_session.ml) share. Each
    works the candidates out from what it knows; this says which word is
    being completed, which names are never offered, and what the
    candidates have in common. See docs/repl.md, "Completion".

    Functions:
      word_before line col -- the word ending at col, and its `m.`.
      qualifier line col -- the `m` of an `m.` before the cursor.
      hidden name -- whether a pass made the name up.
      matching prefix candidates -- the candidates starting with prefix.
      common_prefix names -- what every name starts with. *)

(** The word that ends at column `col` of `line`: where it starts, the
    text so far, and the module written before it with a `.`, if any.
    string -> int -> (int, string, string?) *)
val word_before : string -> int -> int * string * string option

(** The qualifier written before the cursor, as in `m.` or `m.pa`, if
    there is one. string -> int -> string? *)
val qualifier : string -> int -> string option

(** Whether a name was made up by a pass rather than written: a default
    argument's helper, an elaborated overload. string -> bool *)
val hidden : string -> bool

(** The candidates whose name starts with prefix, each once, in
    alphabetical order, leaving out hidden names.
    string -> [(string, string?)] -> [(string, string?)] *)
val matching : string -> (string * string option) list -> (string * string option) list

(** The longest text every name starts with. [string] -> string *)
val common_prefix : string list -> string
