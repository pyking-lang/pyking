(** JSON, read and written: what the language server (lsp.ml) speaks,
    and the standard library has no reader for. A number is kept as a
    float, as JSON itself does; a string holds UTF-8. See design/lsp.md.

    Data structures:
      t -- a JSON value.
      Parse_error -- text that is not JSON.

    Functions:
      parse text -- the value text holds.
      to_string value -- the value as compact JSON text.
      pretty value -- the value as JSON text laid out for reading.
      member name value -- a field of an object, or Null.
      to_string_option / to_int_option / to_list -- a value read as one
        kind, or nothing. *)

(** A JSON value. An object keeps its fields in the order written. *)
type t =
  | Null
  | Bool of bool
  | Number of float
  | String of string
  | List of t list
  | Object of (string * t) list

(** Text that is not JSON, saying where. *)
exception Parse_error of string

(** The value text holds, which must be nothing else but blanks. A
    `\u` escape, surrogate pairs included, becomes UTF-8. Raises
    Parse_error. string -> t *)
val parse : string -> t

(** A value as compact JSON text. t -> string *)
val to_string : t -> string

(** A value as JSON text laid out for reading: each field and element on
    a line of its own, indented two spaces a level, and a newline at the
    end. t -> string *)
val pretty : t -> string

(** A field of an object, or Null where there is none. string -> t -> t *)
val member : string -> t -> t

(** A value as a string, where it is one. t -> string? *)
val to_string_option : t -> string option

(** A value as an integer, where it is a whole number. t -> int? *)
val to_int_option : t -> int option

(** A value as a list, empty where it is not one. t -> [t] *)
val to_list : t -> t list
