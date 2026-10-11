(** JSON, read and written: what the language server (lsp.ml) speaks,
    and the standard library has no reader for. A number is kept as a
    float, as JSON itself does; a string holds UTF-8. See design/lsp.md.

    Data structures:
      t -- a JSON value.
      Parse_error -- text that is not JSON.

    Functions:
      parse text -- the value text holds.
      to_string value -- the value as compact JSON text.
      member name value -- a field of an object, or Null.
      to_string_option / to_int_option / to_list -- a value read as one
        kind, or nothing. *)

type t =
  | Null
  | Bool of bool
  | Number of float
  | String of string
  | List of t list
  | Object of (string * t) list

exception Parse_error of string

(** Adds a code point to a buffer as UTF-8. Buffer.t -> int -> () *)
let add_utf8 buffer code =
  let add c = Buffer.add_char buffer (Char.chr c) in
  if code < 0x80 then add code
  else if code < 0x800 then (
    add (0xC0 lor (code lsr 6));
    add (0x80 lor (code land 0x3F)))
  else if code < 0x10000 then (
    add (0xE0 lor (code lsr 12));
    add (0x80 lor ((code lsr 6) land 0x3F));
    add (0x80 lor (code land 0x3F)))
  else (
    add (0xF0 lor (code lsr 18));
    add (0x80 lor ((code lsr 12) land 0x3F));
    add (0x80 lor ((code lsr 6) land 0x3F));
    add (0x80 lor (code land 0x3F)))

(** The value text holds, which must be nothing else but blanks.
    Raises Parse_error. string -> t *)
let parse text =
  let n = String.length text in
  let fail at what = raise (Parse_error (Printf.sprintf "%s at offset %d" what at)) in
  let rec blank i =
    if i < n && (text.[i] = ' ' || text.[i] = '\n' || text.[i] = '\r' || text.[i] = '\t') then
      blank (i + 1)
    else i
  in
  let expect i word value =
    let k = String.length word in
    if i + k <= n && String.sub text i k = word then (value, i + k) else fail i "unexpected text"
  in
  let hex4 i =
    if i + 4 > n then fail i "short \\u escape"
    else
      match int_of_string_opt ("0x" ^ String.sub text i 4) with
      | Some code -> code
      | None -> fail i "bad \\u escape"
  in
  let string_at i =
    let buffer = Buffer.create 16 in
    let rec go i =
      if i >= n then fail i "unterminated string"
      else
        match text.[i] with
        | '"' -> (Buffer.contents buffer, i + 1)
        | '\\' when i + 1 < n -> (
            match text.[i + 1] with
            | '"' -> Buffer.add_char buffer '"'; go (i + 2)
            | '\\' -> Buffer.add_char buffer '\\'; go (i + 2)
            | '/' -> Buffer.add_char buffer '/'; go (i + 2)
            | 'b' -> Buffer.add_char buffer '\b'; go (i + 2)
            | 'f' -> Buffer.add_char buffer '\012'; go (i + 2)
            | 'n' -> Buffer.add_char buffer '\n'; go (i + 2)
            | 'r' -> Buffer.add_char buffer '\r'; go (i + 2)
            | 't' -> Buffer.add_char buffer '\t'; go (i + 2)
            | 'u' ->
                let code = hex4 (i + 2) in
                if code >= 0xD800 && code < 0xDC00 && i + 12 <= n
                   && text.[i + 6] = '\\' && text.[i + 7] = 'u'
                then (
                  let low = hex4 (i + 8) in
                  add_utf8 buffer (0x10000 + ((code - 0xD800) lsl 10) + (low - 0xDC00));
                  go (i + 12))
                else (
                  add_utf8 buffer code;
                  go (i + 6))
            | _ -> fail i "bad escape")
        | c ->
            Buffer.add_char buffer c;
            go (i + 1)
    in
    go i
  in
  let rec value i =
    let i = blank i in
    if i >= n then fail i "unexpected end"
    else
      match text.[i] with
      | 'n' -> expect i "null" Null
      | 't' -> expect i "true" (Bool true)
      | 'f' -> expect i "false" (Bool false)
      | '"' ->
          let s, i = string_at (i + 1) in
          (String s, i)
      | '[' ->
          let i = blank (i + 1) in
          if i < n && text.[i] = ']' then (List [], i + 1)
          else
            let rec items acc i =
              let v, i = value i in
              let i = blank i in
              if i < n && text.[i] = ',' then items (v :: acc) (i + 1)
              else if i < n && text.[i] = ']' then (List (List.rev (v :: acc)), i + 1)
              else fail i "expected , or ]"
            in
            items [] i
      | '{' ->
          let i = blank (i + 1) in
          if i < n && text.[i] = '}' then (Object [], i + 1)
          else
            let rec fields acc i =
              let i = blank i in
              if i >= n || text.[i] <> '"' then fail i "expected a field name"
              else
                let key, i = string_at (i + 1) in
                let i = blank i in
                if i >= n || text.[i] <> ':' then fail i "expected :"
                else
                  let v, i = value (i + 1) in
                  let i = blank i in
                  if i < n && text.[i] = ',' then fields ((key, v) :: acc) (i + 1)
                  else if i < n && text.[i] = '}' then (Object (List.rev ((key, v) :: acc)), i + 1)
                  else fail i "expected , or }"
            in
            fields [] i
      | '-' | '0' .. '9' ->
          let rec stop j =
            if j < n && String.contains "+-0123456789.eE" text.[j] then stop (j + 1) else j
          in
          let j = stop i in
          (match float_of_string_opt (String.sub text i (j - i)) with
          | Some f -> (Number f, j)
          | None -> fail i "bad number")
      | _ -> fail i "unexpected character"
  in
  let v, i = value 0 in
  if blank i <> n then fail i "text after the value" else v

(** A string as a JSON string literal. string -> string *)
let quote s =
  let buffer = Buffer.create (String.length s + 2) in
  Buffer.add_char buffer '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buffer "\\\""
      | '\\' -> Buffer.add_string buffer "\\\\"
      | '\n' -> Buffer.add_string buffer "\\n"
      | '\r' -> Buffer.add_string buffer "\\r"
      | '\t' -> Buffer.add_string buffer "\\t"
      | c when Char.code c < 0x20 -> Buffer.add_string buffer (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char buffer c)
    s;
  Buffer.add_char buffer '"';
  Buffer.contents buffer

(** A value as compact JSON text. t -> string *)
let rec to_string value =
  match value with
  | Null -> "null"
  | Bool b -> if b then "true" else "false"
  | Number f ->
      if Float.is_integer f && Float.abs f < 1e15 then Printf.sprintf "%.0f" f
      else Printf.sprintf "%.17g" f
  | String s -> quote s
  | List items -> "[" ^ String.concat "," (List.map to_string items) ^ "]"
  | Object fields ->
      "{"
      ^ String.concat "," (List.map (fun (k, v) -> quote k ^ ":" ^ to_string v) fields)
      ^ "}"

(** A field of an object, or Null where there is none. string -> t -> t *)
let member name value =
  match value with
  | Object fields -> Option.value ~default:Null (List.assoc_opt name fields)
  | _ -> Null

(** A value as a string, where it is one. t -> string option *)
let to_string_option value = match value with String s -> Some s | _ -> None

(** A value as an integer, where it is a whole number. t -> int option *)
let to_int_option value =
  match value with
  | Number f when Float.is_integer f -> Some (int_of_float f)
  | _ -> None

(** A value as a list, empty where it is not one. t -> [t] *)
let to_list value = match value with List items -> items | _ -> []
