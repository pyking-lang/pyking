(** The driver of the OCaml bootstrap: reads a Pyking file, runs the
    front end that exists so far -- lexing, parsing, symbolizing, and
    the type checker when `--typecheck` asks for it -- and prints the
    program back out as Pyking source.

    It is deliberately a fraction of src/pyk.py: there are no targets,
    no flags that change what is produced, and no commands. What it does
    have is that driver's error reporting, so a refusal here reads
    exactly as the same refusal does there -- which is what `make
    test-ocaml` compares.

    Functions:
      run filename typecheck symbols -- runs the front end over one
        file and prints the program back out.
      format_error e -- formats a front-end error as one line.
      read_file path -- the contents of a file.
      wrap text -- reflows text to the driver's line width. *)

let usage = "Usage: main [--typecheck] [--symbols] <filename>"

(* Every message this program prints is laid out for a terminal this
   wide, as src/pyk.py's is. *)
let width = 70

(** Reflows text to `width`, continuation lines indented; never breaks a
    word. string -> string *)
let wrap text =
  let words =
    List.filter (fun w -> w <> "") (String.split_on_char ' ' text)
  in
  let rec fill words line lines =
    match words with
    | [] -> List.rev (if line = "" then lines else line :: lines)
    | w :: rest ->
        if line = "" then
          let indent = if lines = [] then "" else "  " in
          fill rest (indent ^ w) lines
        else
          let candidate = line ^ " " ^ w in
          if String.length candidate <= width then fill rest candidate lines
          else fill words "" (line :: lines)
  in
  String.concat "\n" (fill words "" [])

(* One line per stage that can refuse a program, in the order the stages
   run. Every one of these errors carries an info, which is what lets
   them all be reported the same way; the label is the only thing that
   differs. *)

(** Formats a front-end error as `'file' row:col-row:col Kind: message`,
    or None if the exception is not one of them. exn -> string option *)
let format_error error =
  let line label i message =
    Some (wrap (Printf.sprintf "%s %s: %s" (Lexer.pprint_info i) label message))
  in
  match error with
  | Lexer.Lex_error (i, message) -> line "Lexing error" i message
  | Parser.Parse_error (i, message) -> line "Parsing error" i message
  | Analyses.Analysis_error (i, message) -> line "Name error" i message
  | Typesystem.Type_error (i, message) -> line "Type error" i message
  | _ -> None

(** The contents of a file. string -> string *)
let read_file path =
  let channel = open_in_bin path in
  let contents = really_input_string channel (in_channel_length channel) in
  close_in channel;
  contents

(** Runs the front end over one file and prints the program back out.
    With `typecheck`, the checker runs too and every annotation printed
    comes from what it inferred; with `symbols`, each node is labelled
    with the number `symbolize` gave it.
    string -> bool -> bool -> () *)
let run filename typecheck symbols =
  let source = read_file filename in
  let tokens = Lexer.lexing filename (Lexer.chars_of_string source) in
  let program = Parser.parse tokens in
  let program = Analyses.symbolize program in
  let tmap = if typecheck then Some (Typesystem.type_check program) else None in
  print_endline (Syntax.pprint_program program symbols tmap)

let () =
  let arguments = List.tl (Array.to_list Sys.argv) in
  let typecheck = List.mem "--typecheck" arguments in
  let symbols = List.mem "--symbols" arguments in
  let flag a = a = "--typecheck" || a = "--symbols" in
  let positional = List.filter (fun a -> (not (flag a)) && a <> "") arguments in
  match positional with
  | [ filename ] when String.length filename > 0 && filename.[0] <> '-' -> (
      try run filename typecheck symbols with
      | Sys_error message ->
          prerr_endline (wrap message);
          exit 1
      | error -> (
          match format_error error with
          | Some text ->
              prerr_endline text;
              exit 1
          | None -> raise error))
  | _ ->
      prerr_endline usage;
      exit 1
