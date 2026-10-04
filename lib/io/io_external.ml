(* The OCaml implementation of the names declared in io_external.pyk.
   OCaml's own module name comes from this file's name, which is what
   the generated code refers to -- and, loaded into `pyk` as a plugin,
   what the interpreter calls too (docs/libraries.md).

   Every standard-library name is `Stdlib.`-qualified, for the reason
   sys_external.ml gives: a program's own modules sit beside this one.

   An in_channel cannot be peeked at, so `is_eof` reads one character
   and keeps it in `lookahead` for the next read to start with. *)

let lookahead = Stdlib.ref None

(** The next character of standard input, or None at the end. *)
let next () =
  match !lookahead with
  | Some c ->
      lookahead := None;
      Some c
  | None -> ( try Some (Stdlib.input_char Stdlib.stdin) with Stdlib.End_of_file -> None)

let write text = Stdlib.print_string text

let write_line text =
  Stdlib.print_string text;
  Stdlib.print_char '\n'

let prompt_line prompt =
  Stdlib.print_string prompt;
  Stdlib.flush Stdlib.stdout;
  let line = Stdlib.Buffer.create 80 in
  let rec go () =
    match next () with
    | None | Some '\n' -> ()
    | Some c ->
        Stdlib.Buffer.add_char line c;
        go ()
  in
  go ();
  let text = Stdlib.Buffer.contents line in
  let length = Stdlib.String.length text in
  if length > 0 && text.[length - 1] = '\r' then Stdlib.String.sub text 0 (length - 1)
  else text

let read () =
  Stdlib.flush Stdlib.stdout;
  let text = Stdlib.Buffer.create 4096 in
  let rec go () =
    match next () with
    | None -> ()
    | Some c ->
        Stdlib.Buffer.add_char text c;
        go ()
  in
  go ();
  Stdlib.Buffer.contents text

let is_eof () =
  Stdlib.flush Stdlib.stdout;
  match next () with
  | None -> true
  | Some c ->
      lookahead := Some c;
      false
