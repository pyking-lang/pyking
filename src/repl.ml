(** The REPL: `pyk repl`. A session is a program written one entry at a
    time: each entry is checked against what the entries before it left
    behind, then run there. Includes a multi-line terminal line editor
    with history, indentation, and Pyking-aware line completion.
    See docs/repl.md.

    Data structures:
      session -- a REPL session: statements seen, machine state, types,
        store, source text of each definition.
      buffer_ -- the entry being typed: lines, cursor row/col.
      reader -- how entries arrive: the terminal editor, or plain lines
        from a pipe.
      outcome -- what a meta-command leaves behind.

    Functions:
      start format_error -- runs the REPL loop.
      submit session stmts report source -- checks and runs one entry.
      new_session () -- an empty session. *)

open Lexer
open Syntax

let prompt = "> "
let continuation = ". "
let banner = "Pyking REPL.  :help for commands, :quit to leave."

(* One level of indentation, in the only width Pyking accepts (see
   PYKING.md, "Indentation-based blocks"). *)
let indent_width = "    "

(* What the parser says when it stopped because the input ran out rather
   than because it was wrong. A line that ends this way is not an error
   yet: it is an entry that is still being typed. The parser is the only
   thing that knows this, which is why the REPL asks it rather than
   looking for a trailing ':'. *)
let incomplete_reasons = [ "unexpected end of input"; "expected an indented block" ]

let starts_with prefix text =
  String.length text >= String.length prefix
  && String.sub text 0 (String.length prefix) = prefix

(** A REPL session. An entry is checked the way it is run: each is its
    own group, checked and run against what earlier entries left behind
    (see docs/repl.md).
    seen -- every statement given so far, for `symbolize`.
    state -- the machine's names -> values.
    types -- the checker's names -> types.
    store -- what the checker has worked out.
    kinds -- the mutability analysis's names -> kinds.
    sources -- each name's own source text, for `:edit`. *)
type session = {
  seen : stmt list;
  state : Interpreter.state;
  types : Typesystem.env;
  store : Typesystem.store;
  kinds : Analyses.env;
  sources : (string * string) list;
}

(** The mutability analysis's starting environment: the builtins, and
    nothing a `:=` may name. () -> Analyses.env *)
let builtin_kinds () =
  List.fold_left
    (fun env name ->
      Analyses.SMap.add name Analyses.{ kind = Builtin; info = None } env)
    Analyses.SMap.empty Analyses.builtins

(** An empty session: builtins in scope, nothing seen. () -> session *)
let new_session () =
  {
    seen = [];
    state = Interpreter.initial_state [] Interpreter.console_host;
    types = Typesystem.builtin_env ();
    store = Typesystem.empty_store [];
    kinds = builtin_kinds ();
    sources = [];
  }

(* --- reading --- *)

(** source as a list of statements. Raises Lex_error/Parse_error.
    string -> string -> [stmt] *)
let parse_source ?(name = "<repl>") source =
  Parser.parse (Lexer.lexing name (Lexer.chars_of_string (source ^ "\n")))

(** Whether source is a whole entry, per the parser (anything wrong for
    another reason counts as complete). string -> bool *)
let complete source =
  match parse_source source with
  | _ -> true
  | exception Lexer.Lex_error (_, message)
  | exception Parser.Parse_error (_, message) ->
      not (List.exists (fun reason -> starts_with reason message) incomplete_reasons)

(** Whether one statement could take another line. stmt -> bool *)
let rec open_block stmt =
  match stmt with
  | SIf (_, _, _, None, _) -> true
  | SIf (_, _, _, Some else_body, _) -> (
      (* An `else if` rung: the chain ends in the innermost `if`, so that
         is the one an `else` would still attach to. *)
      match List.rev else_body with [] -> false | last :: _ -> open_block last)
  | _ -> false

(** Whether a line the parser accepts could still be continued by the
    line below it: an `if` with no `else` yet. Its block may sit on the
    header's own line, so it parses whole on one line while still being
    open, and the `else` that would follow has to start a line of its own
    (see PYKING.md, "A block on its header's own line"). The question is
    the parser's, like `complete`: it is asked of the tree, not of a
    trailing ':'. string -> bool *)
let continuable source =
  match parse_source source with
  | stmts -> ( match List.rev stmts with [] -> false | last :: _ -> open_block last)
  | exception Lexer.Lex_error _ -> false
  | exception Parser.Parse_error _ -> false

(** The indentation the line after source belongs at: one level in if the
    last line opened a block (ends in ':'), level with it otherwise.
    string -> string *)
let next_indent source =
  let trimmed line = String.trim line <> "" in
  let lines = List.filter trimmed (String.split_on_char '\n' source) in
  match List.rev lines with
  | [] -> ""
  | last :: _ ->
      let length = String.length last in
      let rec spaces i = if i < length && last.[i] = ' ' then spaces (i + 1) else i in
      let indent = String.sub last 0 (spaces 0) in
      let stripped = String.trim last in
      if
        String.length stripped > 0
        && stripped.[String.length stripped - 1] = ':'
      then indent ^ indent_width
      else indent

(* --- the editing buffer ---

   A value with pure operations over it, so that everything about *what
   the text is* can be reasoned about (and tested) without a terminal
   anywhere in sight. The editor below owns the parts that cannot be
   pure: the tty, the history, and the screen. *)

(** The entry being typed: its lines and the cursor's row and column. *)
type buffer_ = { lines : string array; row : int; col : int }

let text_of buf = String.concat "\n" (Array.to_list buf.lines)
let line_of buf = buf.lines.(buf.row)
let empty_buffer = { lines = [| "" |]; row = 0; col = 0 }

(** A buffer holding text, cursor at the end (default) or the start.
    string -> bool -> buffer_ *)
let buffer_of ?(at_end = true) text =
  let lines = Array.of_list (String.split_on_char '\n' text) in
  let lines = if Array.length lines = 0 then [| "" |] else lines in
  if not at_end then { lines; row = 0; col = 0 }
  else
    let last = Array.length lines - 1 in
    { lines; row = last; col = String.length lines.(last) }

(** How much one backspace at col removes: back to the previous
    indentation stop if only spaces precede col, else one character.
    string -> int -> int *)
let indent_step line col =
  if String.trim (String.sub line 0 col) <> "" then 1
  else col - ((col - 1) / String.length indent_width * String.length indent_width)

(** buf with line row replaced by text, cursor at col.
    buffer_ -> int -> string -> int -> buffer_ *)
let with_line buf row text col =
  let lines = Array.copy buf.lines in
  lines.(row) <- text;
  { lines; row; col }

let take text n = String.sub text 0 n
let drop text n = String.sub text n (String.length text - n)

(** Inserts text at the cursor. buffer_ -> string -> buffer_ *)
let insert buf text =
  let line = line_of buf in
  with_line buf buf.row
    (take line buf.col ^ text ^ drop line buf.col)
    (buf.col + String.length text)

(** Splits the line at the cursor, carrying indent onto the new one.
    buffer_ -> string -> buffer_ *)
let newline buf indent =
  let line = line_of buf in
  let head = take line buf.col and tail = drop line buf.col in
  let before = Array.sub buf.lines 0 buf.row in
  let after =
    Array.sub buf.lines (buf.row + 1) (Array.length buf.lines - buf.row - 1)
  in
  {
    lines = Array.concat [ before; [| head; indent ^ tail |]; after ];
    row = buf.row + 1;
    col = String.length indent;
  }

(** Deletes backwards: a whole level of indentation at a time when that
    is what is being deleted (see `indent_step`), else one character.
    buffer_ -> buffer_ *)
let backspace buf =
  if buf.col > 0 then
    let line = line_of buf in
    let width = indent_step line buf.col in
    with_line buf buf.row
      (take line (buf.col - width) ^ drop line buf.col)
      (buf.col - width)
  else if buf.row = 0 then buf
  else
    (* At the start of a line: join it onto the end of the one above. *)
    let above = buf.lines.(buf.row - 1) in
    let before = Array.sub buf.lines 0 (buf.row - 1) in
    let after =
      Array.sub buf.lines (buf.row + 1) (Array.length buf.lines - buf.row - 1)
    in
    {
      lines = Array.concat [ before; [| above ^ line_of buf |]; after ];
      row = buf.row - 1;
      col = String.length above;
    }

(** Deletes the character at the cursor. buffer_ -> buffer_ *)
let delete buf =
  let line = line_of buf in
  if buf.col < String.length line then
    with_line buf buf.row (take line buf.col ^ drop line (buf.col + 1)) buf.col
  else if buf.row = Array.length buf.lines - 1 then buf
  else
    let joined = line ^ buf.lines.(buf.row + 1) in
    let before = Array.sub buf.lines 0 buf.row in
    let after =
      Array.sub buf.lines (buf.row + 2) (Array.length buf.lines - buf.row - 2)
    in
    { lines = Array.concat [ before; [| joined |]; after ]; row = buf.row; col = buf.col }

(** Deletes from the cursor to the end of the line. buffer_ -> buffer_ *)
let kill_to_end buf = with_line buf buf.row (take (line_of buf) buf.col) buf.col

(** Moves the cursor left one character, across line boundaries.
    buffer_ -> buffer_ *)
let left buf =
  if buf.col > 0 then { buf with col = buf.col - 1 }
  else if buf.row = 0 then buf
  else
    { buf with row = buf.row - 1; col = String.length buf.lines.(buf.row - 1) }

(** Moves the cursor right one character, across line boundaries.
    buffer_ -> buffer_ *)
let right buf =
  if buf.col < String.length (line_of buf) then { buf with col = buf.col + 1 }
  else if buf.row = Array.length buf.lines - 1 then buf
  else { buf with row = buf.row + 1; col = 0 }

(** One line up, keeping the column where it fits, or None if already on
    the first line. buffer_ -> buffer_ option *)
let up buf =
  if buf.row = 0 then None
  else
    Some
      {
        buf with
        row = buf.row - 1;
        col = min buf.col (String.length buf.lines.(buf.row - 1));
      }

(** One line down, or None if already on the last line.
    buffer_ -> buffer_ option *)
let down buf =
  if buf.row = Array.length buf.lines - 1 then None
  else
    Some
      {
        buf with
        row = buf.row + 1;
        col = min buf.col (String.length buf.lines.(buf.row + 1));
      }

let home buf = { buf with col = 0 }
let end_ buf = { buf with col = String.length (line_of buf) }

(* --- the terminal editor ---

   The keys the editor understands, as names rather than escape
   sequences, so that the dispatch below reads as editing rather than as
   terminal trivia. *)

let arrow_key letter =
  match letter with
  | "A" -> Some "up"
  | "B" -> Some "down"
  | "C" -> Some "right"
  | "D" -> Some "left"
  | "H" -> Some "home"
  | "F" -> Some "end"
  | _ -> None

let tilde_key number =
  match number with
  | 1 | 7 -> "home"
  | 3 -> "delete"
  | 4 | 8 -> "end"
  | _ -> "ignored"

let control_key char =
  match char with
  | "\r" | "\n" -> Some "enter"
  | "\t" -> Some "tab"
  | "\x7f" | "\b" -> Some "backspace"
  | "\x01" -> Some "home"
  | "\x05" -> Some "end"
  | "\x0b" -> Some "kill"
  | "\x03" -> Some "interrupt"
  | "\x04" -> Some "eof"
  | "\x0c" -> Some "clear"
  | _ -> None

(* The keycode a terminal reports for Return when it reports keys as
   numbers rather than as characters, and the modifier bit for Shift. A
   terminal in "CSI u" mode sends Shift+Return as `\x1b[13;2u`, and one
   using xterm's older `modifyOtherKeys` as `\x1b[27;2;13~`; both are
   read below. A terminal doing neither sends a plain `\r` for
   Shift+Return, indistinguishable from Return itself. *)
let return_key = 13
let shift = 2

(* How long to wait for the rest of an escape sequence before concluding
   that the Escape key was pressed on its own. An arrow key sends its
   bytes in one burst, so anything still absent after this came from a
   human finger. *)
let escape_delay = 0.05

(** How entries arrive: `read` answers one entry (None at end of input,
    "" if abandoned), `ask` puts a question and reads one key, and
    `interactive` says whether there is a terminal to edit in. *)
type reader = {
  read : string -> string option;
  ask : string -> string;
  interactive : bool;
}

(** Runs f with the terminal in raw mode, restoring it afterwards. A
    terminal that cannot be put in raw mode is left alone.

    stdout is flushed on both sides of each switch. Raw mode turns off
    output post-processing, so a '\n' written there is a line feed and
    nothing more; text buffered in canonical mode and flushed inside f
    would come out down a line but not back at the left margin.
    (unit -> 'a) -> 'a *)
let with_raw f =
  match Unix.tcgetattr Unix.stdin with
  | exception _ -> f ()
  | saved ->
      let raw =
        {
          saved with
          Unix.c_brkint = false;
          c_icrnl = false;
          c_inpck = false;
          c_istrip = false;
          c_ixon = false;
          c_opost = false;
          c_csize = 8;
          c_parenb = false;
          c_echo = false;
          c_icanon = false;
          c_isig = false;
          c_vmin = 1;
          c_vtime = 0;
        }
      in
      flush stdout;
      Unix.tcsetattr Unix.stdin Unix.TCSADRAIN raw;
      Fun.protect
        ~finally:(fun () ->
          flush stdout;
          Unix.tcsetattr Unix.stdin Unix.TCSADRAIN saved)
        f

(** How wide the terminal is: what $COLUMNS says, else what `stty size`
    reports, else 80. Asked once per entry rather than once per
    keystroke, which is what OCaml can do without an ioctl of its own.
    () -> int *)
let terminal_columns () =
  match Option.bind (Sys.getenv_opt "COLUMNS") int_of_string_opt with
  | Some columns when columns > 0 -> columns
  | _ -> (
      match Unix.open_process_in "stty size 2>/dev/null" with
      | exception _ -> 80
      | channel ->
          let line = try input_line channel with End_of_file -> "" in
          ignore (Unix.close_process_in channel);
          (match List.filter_map int_of_string_opt (String.split_on_char ' ' line) with
          | [ _; columns ] when columns > 0 -> columns
          | _ -> 80))

(** The terminal editor: a multi-line editor over a terminal in raw
    mode, with history of whole entries (not lines, unlike readline).
    `is_complete` and `indent_for` are the only things it needs to know
    about the language: whether Enter submits, and how far the next line
    indents. The history, the width and where the last drawing left the
    cursor are the terminal's own state, so they are cells rather than
    threaded values.
    (string -> bool) -> (string -> string) -> reader *)
let editor is_complete indent_for =
  let history = ref [] in
  let rows_up = ref 0 in
  let rows_total = ref 1 in
  let columns = ref 80 in
  let write text =
    print_string text;
    flush stdout
  in
  let prompt_for row = if row = 0 then prompt else continuation in
  let move from_row (to_row, to_column) =
    let moves =
      if from_row > to_row then Printf.sprintf "\x1b[%dA" (from_row - to_row)
      else if from_row < to_row then Printf.sprintf "\x1b[%dB" (to_row - from_row)
      else ""
    in
    moves ^ "\r" ^ if to_column > 0 then Printf.sprintf "\x1b[%dC" to_column else ""
  in
  (* One redraw per keystroke: go back to the top of what was drawn last
     time, clear it, write the entry out again, and put the cursor where
     the buffer says it is. Rows are counted with the terminal's width in
     mind, so a line long enough to wrap is still followed correctly. *)
  let draw buf =
    let width = !columns in
    let out = Buffer.create 128 in
    if !rows_up > 0 then Buffer.add_string out (Printf.sprintf "\x1b[%dA" !rows_up);
    Buffer.add_string out "\r\x1b[J";
    let row = ref 0 in
    let cursor = ref (0, 0) in
    Array.iteri
      (fun index line ->
        let text = prompt_for index ^ line in
        Buffer.add_string out ((if index > 0 then "\r\n" else "") ^ text);
        if index = buf.row then begin
          let at = String.length (prompt_for index) + buf.col in
          cursor := (!row + (at / width), at mod width)
        end;
        row := !row + (String.length text / width) + 1)
      buf.lines;
    (* A line that ends exactly at the right margin leaves the cursor in
       a position terminals disagree about, so it is forced over to the
       next row and the space that forced it is erased again. *)
    let last_index = Array.length buf.lines - 1 in
    let last =
      String.length (prompt_for last_index) + String.length buf.lines.(last_index)
    in
    if last > 0 && last mod width = 0 then Buffer.add_string out " \r\x1b[K";
    rows_total := !row;
    rows_up := fst !cursor;
    Buffer.add_string out (move (!row - 1) !cursor);
    write (Buffer.contents out)
  in
  let to_bottom () =
    let below = !rows_total - 1 - !rows_up in
    if below > 0 then write (Printf.sprintf "\x1b[%dB" below);
    write "\r"
  in
  (* Reads one character, decoding UTF-8 if needed, or None at end of
     input. *)
  let read_char () =
    let one = Bytes.create 1 in
    if Unix.read Unix.stdin one 0 1 = 0 then None
    else
      let first = Char.code (Bytes.get one 0) in
      let length =
        if first < 0x80 then 1
        else if first lsr 5 = 0b110 then 2
        else if first lsr 4 = 0b1110 then 3
        else 4
      in
      let buffer = Buffer.create 4 in
      Buffer.add_char buffer (Bytes.get one 0);
      for _ = 2 to length do
        if Unix.read Unix.stdin one 0 1 > 0 then
          Buffer.add_char buffer (Bytes.get one 0)
      done;
      Some (Buffer.contents buffer)
  in
  let waiting () =
    match Unix.select [ Unix.stdin ] [] [] escape_delay with
    | ready, _, _ -> ready <> []
    | exception _ -> false
  in
  (* The key a control sequence stands for, from its parameters and its
     final letter. *)
  let named parameters final =
    let numbers =
      List.filter_map int_of_string_opt (String.split_on_char ';' parameters)
    in
    match (final, numbers) with
    | "u", key :: modifier :: _ when key = return_key && modifier >= shift ->
        "submit"
    (* xterm's `modifyOtherKeys`, which says the keycode last. *)
    | "~", [ 27; modifier; key ] when key = return_key && modifier >= shift ->
        "submit"
    | "~", number :: _ -> tilde_key number
    | letter, _ -> ( match arrow_key letter with Some name -> name | None -> "ignored")
  in
  (* Reads a \x1b[ sequence to its final letter and names it. *)
  let rec control_sequence parameters =
    match read_char () with
    | None -> "ignored"
    | Some char ->
        let c = char.[0] in
        if String.length char = 1 && ((c >= '0' && c <= '9') || c = ';') then
          control_sequence (parameters ^ char)
        else named parameters char
  in
  (* The key an Escape byte started: "escape" alone, "submit" for a
     modified Return, or a control-sequence key. *)
  let escape () =
    if not (waiting ()) then "escape"
    else
      match read_char () with
      (* Return with something held down -- Alt or Shift, depending on
         the terminal. Either way it means "this entry is finished". *)
      | Some "\r" | Some "\n" -> "submit"
      | Some "[" -> control_sequence ""
      | _ -> "ignored"
  in
  (* The next key, as `Text characters` or `Key name`. *)
  let key () =
    match read_char () with
    | None -> `Key "eof"
    | Some "\x1b" -> `Key (escape ())
    | Some char -> (
        match control_key char with
        | Some name -> `Key name
        | None -> if char < " " then `Key "ignored" else `Text char)
  in
  (* Whether Enter ends the entry: a single complete line that nothing
     could continue does; anything else ends on a blank line. *)
  let submits buf =
    if Array.length buf.lines = 1 then
      is_complete (text_of buf) && not (continuable (text_of buf))
    else String.trim (line_of buf) = ""
  in
  (* buf's text, with the trailing blank line dropped. *)
  let submitted buf =
    let lines = ref (Array.to_list buf.lines) in
    let rec trim list =
      match List.rev list with
      | last :: rest when List.length list > 1 && String.trim last = "" ->
          trim (List.rev rest)
      | _ -> list
    in
    lines := trim !lines;
    String.concat "\n" !lines
  in
  (* The text above and including the cursor's line, for indent_for. *)
  let before buf =
    String.concat "\n" (Array.to_list (Array.sub buf.lines 0 (buf.row + 1)))
  in
  (* Leaves the entry on screen, moves the cursor below it, and records
     the result in history. *)
  let finish result =
    to_bottom ();
    write "\r\n";
    (match result with
    | Some text
      when String.trim text <> ""
           && (!history = [] || List.nth !history (List.length !history - 1) <> text)
      ->
        history := !history @ [ text ]
    | _ -> ());
    result
  in
  let read initial =
    let buf = if initial = "" then empty_buffer else buffer_of initial in
    columns := terminal_columns ();
    with_raw (fun () ->
        rows_up := 0;
        rows_total := 1;
        draw buf;
        let rec loop buf live index =
          match key () with
          | `Text char ->
              let buf = insert buf char in
              draw buf;
              loop buf live index
          | `Key name -> (
              match name with
              | "enter" when submits buf -> finish (Some (submitted buf))
              (* Shift+Return: this entry is finished, whatever it looks
                 like -- the way out of a block without the blank line,
                 and the only key here that is about *ending* rather than
                 editing. *)
              | "submit" -> finish (Some (submitted buf))
              | "escape" | "interrupt" -> finish (Some "")
              | "eof" when text_of buf = "" -> finish None
              | name ->
                  let buf, live, index =
                    match name with
                    | "enter" -> (newline buf (indent_for (before buf)), live, index)
                    | "tab" -> (insert buf indent_width, live, index)
                    | "backspace" -> (backspace buf, live, index)
                    | "delete" -> (delete buf, live, index)
                    | "kill" -> (kill_to_end buf, live, index)
                    | "left" -> (left buf, live, index)
                    | "right" -> (right buf, live, index)
                    | "home" -> (home buf, live, index)
                    | "end" -> (end_ buf, live, index)
                    | "clear" ->
                        write "\x1b[H\x1b[J";
                        rows_up := 0;
                        (buf, live, index)
                    | "up" -> (
                        match up buf with
                        | Some moved -> (moved, live, index)
                        | None ->
                            if index > 0 then
                              let live =
                                if index = List.length !history then text_of buf
                                else live
                              in
                              (buffer_of (List.nth !history (index - 1)), live, index - 1)
                            else (buf, live, index))
                    | "down" -> (
                        match down buf with
                        | Some moved -> (moved, live, index)
                        | None ->
                            if index < List.length !history then
                              let index = index + 1 in
                              ( buffer_of
                                  (if index < List.length !history then
                                     List.nth !history index
                                   else live),
                                live,
                                index )
                            else (buf, live, index))
                    | _ -> (buf, live, index)
                  in
                  draw buf;
                  loop buf live index)
        in
        loop buf "" (List.length !history))
  in
  let ask message =
    write
      (String.concat "\r\n" (String.split_on_char '\n' message) ^ "\r\n");
    let answer = with_raw (fun () -> key ()) in
    match answer with
    | `Key ("escape" | "interrupt" | "eof") -> "cancel"
    | _ -> "edit"
  in
  { read; ask; interactive = true }

(** One entry, a line at a time from read_line (the non-terminal
    fallback). Answers the source text, or None at end of input.
    (string -> string option) -> string option *)
let read_entry read_line =
  match read_line prompt with
  | None -> None
  | Some line ->
      if complete line && not (continuable line) then
        (* A block that parses is not necessarily finished (`if c: 1`
           parses fine, but `else: 2` may follow on the next line), so a
           single line is submitted without a blank line only when
           nothing could continue it. *)
        Some line
      else
        let rec more lines =
          match read_line continuation with
          | None -> Some (String.concat "\n" (List.rev lines))
          | Some line when String.trim line = "" ->
              Some (String.concat "\n" (List.rev lines))
          | Some line -> more (line :: lines)
        in
        more [ line ]

(** Reads entries from something that is not a terminal (a pipe, a
    transcript). Ignores `initial` and answers every `ask` with "cancel".
    () -> reader *)
let pipe_reader () =
  let read _initial =
    read_entry (fun shown ->
        print_string shown;
        flush stdout;
        match input_line stdin with
        | line -> Some line
        | exception End_of_file -> None)
  in
  { read; ask = (fun _ -> "cancel"); interactive = false }

(** An editor if stdin is a terminal, a pipe reader otherwise.
    () -> reader *)
let make_reader () =
  if Unix.isatty Unix.stdin then editor complete next_indent else pipe_reader ()

(* --- accepting an entry --- *)

(** The names a top-level statement binds. stmt -> [string] *)
let defined_names stmt =
  match stmt with
  | SFunctionDef (_, name, _, _, _, _, _) -> [ name ]
  | stmt -> List.map fst (Analyses.bound_names stmt)

(** The whole lines of source a statement covers. string -> stmt
    -> string *)
let statement_source source stmt =
  let lines = Array.of_list (String.split_on_char '\n' source) in
  let info = stmt_info stmt in
  let first = max 0 (info.row1 - 1) in
  let last = min (Array.length lines) info.row2 in
  if first >= last then ""
  else String.concat "\n" (Array.to_list (Array.sub lines first (last - first)))

(** What stmt defined, as name -> the source text that defined it (sliced
    from source by whole lines, or printed back where there is no
    source). stmt -> string -> [(string, string)] *)
let defined_sources stmt source =
  match defined_names stmt with
  | [] -> []
  | names ->
      let text =
        if source <> "" then statement_source source stmt
        else pprint_program [ stmt ] false None
      in
      List.map (fun name -> (name, text)) names

(** An association list with `name` set to `text`: the existing entry
    replaced where there is one, and a new entry appended where there is
    not, so the order names were bound in survives.
    string -> string -> [(string, string)] -> [(string, string)] *)
let rec set_source name text = function
  | [] -> [ (name, text) ]
  | (held, _) :: rest when held = name -> (name, text) :: rest
  | pair :: rest -> pair :: set_source name text rest

(** Checks entry as one group (defs declared together via
    `declare_functions`, then `check_stmt` per statement), keeping each
    statement's environment and store rather than only the last. The
    table it filled comes back too: the tail-call pass reads it.
    [stmt] -> Typesystem.env -> Typesystem.store
    -> ([(stmt, typ option, Typesystem.env, Typesystem.store)], typ IntMap.t) *)
let check_entry entry types store =
  let types, store = Typesystem.declare_functions entry types store in
  let store = { store with Typesystem.tmap = IntMap.empty } in
  let checked, _, store =
    List.fold_left
      (fun (checked, types, store) stmt ->
        let supplied, types, store =
          Typesystem.check_stmt stmt types Typesystem.No_function None store
        in
        (checked @ [ (stmt, supplied, types, store) ], types, store))
      ([], types, store) entry
  in
  (checked, store.Typesystem.tmap)

(** A value as the prompt shows it: `display_value`, except a function
    shows as <function>. Interpreter.value -> string *)
let value_text value =
  match value with
  | Interpreter.VClosure _ | Interpreter.VBuiltin _ -> "<function>"
  | value -> Interpreter.display_value value

(** ` : Type`, or "" if there is no type. A type the checker has not
    settled prints with `?` where it is still open -- an unannotated
    `def` has none until something calls it (see
    docs/type_inference.md), and `?` is what `displayed` renders that
    as. The prompt is the one place it is shown rather than suppressed:
    a session is a conversation about what is known so far, so "not
    known yet" is worth seeing. typ option -> string *)
let type_suffix type_ =
  match type_ with
  | None -> ""
  | Some type_ -> " : " ^ pprint_type default_config type_

(** Prints value as `value : Type`, or nothing for unit.
    Interpreter.value option -> typ option -> () *)
let show value type_ =
  match value with
  | None | Some Interpreter.VUnit -> ()
  | Some value -> print_endline (value_text value ^ type_suffix type_)

(** Checks stmts as one entry (all of it, before any of it runs), then
    runs whichever of them the checker accepted, reporting any runtime
    error via report. `source` is kept per-name for `:edit`. Answers the
    session and the check-time error, if any, left for the caller to
    handle rather than reported here.
    session -> [stmt] -> (exn -> ()) -> string -> (session, exn option) *)
let submit session stmts report source =
  let seen = Analyses.symbolize (session.seen @ stmts) in
  let entry = List.filteri (fun i _ -> i >= List.length session.seen) seen in
  match
    try
      let checked, tmap = check_entry entry session.types session.store in
      (* The one rule types do not state, asked of the entry as a block,
         exactly as `pyk` asks it of a file. *)
      let kinds = Analyses.analyze_stmts entry session.kinds in
      Ok (checked, tmap, kinds, seen, entry)
    with
    | Analyses.Analysis_error _ as e -> Error e
    | Typesystem.Type_error _ as e -> Error e
  with
  | Error e -> (session, Some e)
  | Ok (checked, tmap, kinds, seen, entry) -> (
      (* An entry's tail calls become loops here as they would in a file,
         so a function written at the prompt runs the way `pyk <file>`
         runs it (see docs/optimization.md). The pass needs the types, so
         it goes after the check; the entry is then checked again, not to
         verify it -- the rewrite preserves typing -- but because a
         merged group is a different number of statements, and the prompt
         shows a type per statement it runs. The pass is over the entry
         alone, which is exactly right: an entry is its own group of
         `def`s. *)
      let optimized, _ = Optimization.optimize entry tmap in
      let checked, seen, entry =
        if optimized = entry then (checked, seen, entry)
        else
          let seen = Analyses.symbolize (session.seen @ optimized) in
          let entry =
            List.filteri (fun i _ -> i >= List.length session.seen) seen
          in
          let checked, _ = check_entry entry session.types session.store in
          (checked, seen, entry)
      in
      (* `seen` grows whether or not every statement runs: a symbol
         handed out once must not be handed out again. *)
      let session = { session with seen; kinds } in
      let state = Interpreter.declare_entry session.state entry in
      let rec run session state checked =
        match checked with
        | [] -> (session, None)
        | (stmt, supplied, types, store) :: rest -> (
            let after = Interpreter.eval_in state stmt in
            match Interpreter.failure after with
            | Some error ->
                report error;
                ({ session with state }, None)
            | None ->
                let session =
                  {
                    session with
                    state = after;
                    types;
                    store;
                    sources =
                      List.fold_left
                        (fun sources (name, text) -> set_source name text sources)
                        session.sources
                        (defined_sources stmt source);
                  }
                in
                show (Interpreter.result after)
                  (Option.map
                     (fun s ->
                       Typesystem.displayed (Typesystem.zonk s store) store)
                     supplied);
                run session after rest)
      in
      run { session with state } state checked)

(** `submit`, with a refusal simply reported -- for callers with nothing
    better to do with one than say so.
    session -> [stmt] -> (exn -> ()) -> string -> session *)
let accept session stmts report source =
  let session, refused = submit session stmts report source in
  (match refused with Some error -> report error | None -> ());
  session

(** name -> Type for what the session has bound, read back against its
    store (so a deferred function shows what it turned out to be, and a
    type still being worked out shows what has been settled), in the
    order the session bound them -- which is the order `sources` records,
    since a name reaches both at the same statement.
    session -> [(string, typ)] *)
let binding_types session =
  let settled type_ =
    Typesystem.displayed
      (Typesystem.zonk (Typesystem.settled_type type_ session.store) session.store)
      session.store
  in
  let named name =
    match Typesystem.SMap.find_opt name session.types with
    | Some (TBuiltin _) | None -> None
    | Some type_ -> Some (name, settled type_)
  in
  let ordered = List.filter_map (fun (name, _) -> named name) session.sources in
  ordered
  @ Typesystem.SMap.fold
      (fun name type_ found ->
        if List.mem_assoc name ordered then found
        else
          match type_ with
          | TBuiltin _ -> found
          | type_ -> found @ [ (name, settled type_) ])
      session.types []

(* --- meta-commands ---

   Each takes the session and the argument text, and answers the session
   to carry on with -- so a command that changes the session (`:load`,
   `:reset`) and one that only reports (`:type`, `:ls`) have the same
   shape, and the loop needs to know nothing about which is which. *)

(** What a meta-command leaves behind: the session, and text to put back
    in front of the user (only `:edit` sets that). *)
type outcome = { out_session : session; pending : string }

let plain session = { out_session = session; pending = "" }

let help_text =
  "\n\
   Commands:\n\
  \  :help            this help list\n\
  \  :quit, :q        leave (or type Ctrl-D)\n\
  \  :ls              list all bound values and variables\n\
  \  :type <expr>     the type of expression <expr>\n\
  \  :edit <name>     edit defined <name> again\n\
  \  :ast <stmt>      the parsed form of <stmt>\n\
  \  :tokens <line>   the token stream for <line>\n\
  \  :load <file>     read a file into the session\n\
  \  :reset           forget everything and start again\n"

let meta_help session _argument _report =
  print_endline help_text;
  plain session

(** Prints what the session has bound, as `name = value : Type`
    (builtins excluded), in binding order. *)
let meta_ls session _argument _report =
  let bindings = Interpreter.bindings_in_scope session.state.Interpreter.env in
  let types = binding_types session in
  let names =
    List.filter (fun (name, _) -> List.mem_assoc name bindings) types
    |> List.map fst
  in
  let names =
    names
    @ List.filter_map
        (fun (name, _) ->
          if List.mem_assoc name types || List.mem name Analyses.builtins then None
          else Some name)
        bindings
  in
  (if names = [] then print_endline "no bindings yet"
   else
     let width =
       List.fold_left (fun width name -> max width (String.length name)) 0 names
     in
     List.iter
       (fun name ->
         let value =
           value_text (List.assoc name bindings)
           ^ type_suffix (List.assoc_opt name types)
         in
         Printf.printf "%s%s = %s\n" name
           (String.make (width - String.length name) ' ')
           value)
       names);
  plain session

(** Prints the type of the expression argument, checked in the session's
    own type environment. *)
let meta_type session argument report =
  if argument = "" then (
    print_endline "usage: :type <expression>";
    plain session)
  else
    match parse_source argument with
    | exception (Lexer.Lex_error _ as e) ->
        report e;
        plain session
    | exception (Parser.Parse_error _ as e) ->
        report e;
        plain session
    | [ SExprStmt (_, e, _) ] -> (
        match Typesystem.check_expr e session.types session.store with
        | checked, store ->
            print_endline
              (pprint_type default_config
                 (Typesystem.displayed
                    (Typesystem.zonk (Typesystem.settled_type checked store) store)
                    store));
            plain session
        | exception (Analyses.Analysis_error _ as e) ->
            report e;
            plain session
        | exception (Typesystem.Type_error _ as e) ->
            report e;
            plain session)
    | _ ->
        print_endline ":type takes one expression";
        plain session

(** Prints the parsed form of the statement argument. *)
let meta_ast session argument report =
  if argument = "" then (
    print_endline "usage: :ast <statement>";
    plain session)
  else
    match parse_source argument with
    | stmts ->
        print_endline (pprint_program stmts false None);
        plain session
    | exception (Lexer.Lex_error _ as e) ->
        report e;
        plain session
    | exception (Parser.Parse_error _ as e) ->
        report e;
        plain session

(** Prints the token stream for the line argument. *)
let meta_tokens session argument report =
  (match Lexer.lexing "<repl>" (Lexer.chars_of_string (argument ^ "\n")) with
  | tokens ->
      List.iter
        (fun token ->
          Printf.printf "%s %s\n"
            (Lexer.pprint_info (Lexer.token_info token))
            (Lexer.pprint_token token))
        tokens
  | exception (Lexer.Lex_error _ as e) -> report e);
  plain session

(** Reads a file and submits its statements as one entry. *)
let meta_load session argument report =
  if argument = "" then (
    print_endline "usage: :load <file>";
    plain session)
  else
    match
      let channel = open_in_bin argument in
      let source = really_input_string channel (in_channel_length channel) in
      close_in channel;
      source
    with
    | exception Sys_error message ->
        Printf.printf "cannot read '%s': %s\n" argument message;
        plain session
    | source -> (
        match parse_source ~name:argument source with
        | stmts -> plain (accept session stmts report source)
        | exception (Lexer.Lex_error _ as e) ->
            report e;
            plain session
        | exception (Parser.Parse_error _ as e) ->
            report e;
            plain session)

(** Puts the source text that defined argument back into the prompt to
    edit and re-enter. *)
let meta_edit session argument _report =
  if argument = "" then (
    print_endline "usage: :edit <name>";
    plain session)
  else
    match List.assoc_opt argument session.sources with
    | None ->
        Printf.printf "nothing named '%s' was defined in this session\n" argument;
        plain session
    | Some text -> { out_session = session; pending = text }

(** Starts a new, empty session. *)
let meta_reset _session _argument _report =
  print_endline "session reset";
  plain (new_session ())

let meta_commands =
  [
    (":help", meta_help);
    (":ls", meta_ls);
    (":type", meta_type);
    (":edit", meta_edit);
    (":ast", meta_ast);
    (":tokens", meta_tokens);
    (":load", meta_load);
    (":reset", meta_reset);
  ]

let quit_commands = [ ":quit"; ":q" ]

(** Runs the meta-command in line, or reports "unknown command".
    session -> string -> (exn -> ()) -> outcome *)
let run_meta session line report =
  let word, argument =
    match String.index_opt line ' ' with
    | None -> (line, "")
    | Some i -> (String.sub line 0 i, String.trim (drop line (i + 1)))
  in
  match List.assoc_opt word meta_commands with
  | None ->
      Printf.printf "unknown command '%s'; :help lists them\n" word;
      plain session
  | Some command -> command session argument report

(* --- the loop --- *)

(* What the front end says when a name resolves to nothing. Read here
   rather than re-derived: the wording is analyses.ml's, in one place,
   and this is the one caller that wants the *name* out of it rather
   than the sentence. *)
let unbound_prefix = "unbound name '"

(** The name an "unbound name" error is about, or None.
    exn -> string option *)
let undefined_name error =
  match error with
  | Analyses.Analysis_error (_, message) when starts_with unbound_prefix message ->
      let rest = drop message (String.length unbound_prefix) in
      Some
        (if String.length rest > 0 && rest.[String.length rest - 1] = '\'' then
           take rest (String.length rest - 1)
         else rest)
  | _ -> None

(** The prompt shown when a def names something not yet defined.
    string -> string *)
let undefined_message name =
  Printf.sprintf
    "Identifier '%s' is not yet defined. Press <esc> to cancel or <space> to \
     continue editing."
    name

(** Whether stmts include a def. [stmt] -> bool *)
let defines_function stmts =
  List.exists (fun s -> match s with SFunctionDef _ -> true | _ -> false) stmts

(** Runs the REPL loop until end of input or `:quit`. `format_error` is
    the driver's (pyk.ml). (exn -> string option) -> int *)
let start ?read ?session format_error =
  let reader = match read with Some reader -> reader | None -> make_reader () in
  let report error =
    match format_error error with
    | Some text -> prerr_endline text
    | None -> raise error
  in
  print_endline banner;
  let rec loop session pending =
    match reader.read pending with
    | None ->
        print_newline ();
        0
    | Some source -> (
        let line = String.trim source in
        if line = "" then loop session ""
        else if List.mem line quit_commands then 0
        else if starts_with ":" line then
          let outcome = run_meta session line report in
          let pending = outcome.pending in
          if pending <> "" && not reader.interactive then (
            (* Nothing to edit it with, so showing it is the whole of
               what `:edit` can do here. *)
            print_endline pending;
            loop outcome.out_session "")
          else loop outcome.out_session pending
        else
          match parse_source source with
          | exception (Lexer.Lex_error _ as e) ->
              report e;
              loop session ""
          | exception (Parser.Parse_error _ as e) ->
              report e;
              loop session ""
          | stmts -> (
              let session, refused = submit session stmts report source in
              match refused with
              | None -> loop session ""
              | Some refused -> (
                  match undefined_name refused with
                  | Some name
                    when defines_function stmts && reader.interactive ->
                      if reader.ask (undefined_message name) = "edit" then
                        loop session source
                      else loop session ""
                  | _ ->
                      report refused;
                      loop session "")))
  in
  loop (match session with Some session -> session | None -> new_session ()) ""
