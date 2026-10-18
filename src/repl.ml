(** The REPL: `pyk repl`, the terminal half. The session itself -- how
    an entry is checked against the ones before it and run -- is
    repl_session.ml's, which the playground shares; this module adds the
    multi-line terminal line editor with history, indentation, and
    Pyking-aware line completion, `:load` and `:quit`, and the loop.
    See docs/repl.md.

    Data structures:
      buffer_ -- the entry being typed: lines, cursor row/col.
      reader -- how entries arrive: the terminal editor, or plain lines
        from a pipe.

    Functions:
      start format_error -- runs the REPL loop. *)

open Repl_session

type session = Repl_session.session

let prompt = "> "
let continuation = ". "
let banner = "Pyking REPL.  :help for commands, :quit to leave."

let starts_with prefix text =
  String.length text >= String.length prefix
  && String.sub text 0 (String.length prefix) = prefix


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
    "" if abandoned), completing a word on Tab with the function it is
    handed (Repl_session.completions), `ask` puts a question and reads
    one key, and `interactive` says whether there is a terminal to edit
    in. *)
type reader = {
  read : (string -> int -> int * (string * string option) list) -> string -> string option;
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
    indents. `idle` lets a plugin answer what is waiting for it. The history, the width and where the last drawing left the
    cursor are the terminal's own state, so they are cells rather than
    threaded values.
    (string -> bool) -> (string -> string) -> (() -> ()) -> reader *)
let editor is_complete indent_for idle =
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
  (* The terminal as it was before the editor took it over, which is
     how a plugin's output is written while an entry is being typed. *)
  let cooked = try Some (Unix.tcgetattr Unix.stdin) with Unix.Unix_error _ -> None in
  (* While a plugin serves something -- tinyweb's page -- waiting for a
     key is also waiting for it: what it does is written above the entry
     being typed, which is then drawn again below it. *)
  let rec wait_for_key buf =
    match List.map (fun d : Unix.file_descr -> Obj.obj d) (Pyk_plugin.idle_descriptors ()) with
    | [] -> ()
    | watched ->
        let ready =
          match Unix.select (Unix.stdin :: watched) [] [] (-1.0) with
          | ready, _, _ -> ready
          | exception Unix.Unix_error (Unix.EINTR, _, _) -> []
        in
        if not (List.mem Unix.stdin ready) then begin
          if ready <> [] then begin
            if !rows_up > 0 then write (Printf.sprintf "\x1b[%dA" !rows_up);
            write "\r\x1b[J";
            let raw = Unix.tcgetattr Unix.stdin in
            Option.iter (Unix.tcsetattr Unix.stdin Unix.TCSADRAIN) cooked;
            idle ();
            flush stdout;
            Unix.tcsetattr Unix.stdin Unix.TCSADRAIN raw;
            rows_up := 0;
            rows_total := 1;
            draw buf
          end;
          wait_for_key buf
        end
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
  (* Tab: an indentation step where only spaces are before the cursor,
     and otherwise the word before it completed -- outright where one
     name fits, as far as every fitting name agrees where several do,
     and with the names listed below the entry where they agree no
     further. *)
  let tab complete buf =
    let line = line_of buf in
    if String.trim (String.sub line 0 buf.col) = "" then insert buf indent_width
    else
      let start, items = complete line buf.col in
      let typed = buf.col - start in
      let names = List.map fst items in
      let shared = Completion.common_prefix names in
      if items = [] then buf
      else if String.length shared > typed then
        insert buf (String.sub shared typed (String.length shared - typed))
      else begin
        to_bottom ();
        let widest = List.fold_left (fun w n -> max w (String.length n)) 0 names in
        let shown =
          List.map
            (fun (name, detail) ->
              match detail with
              | Some d -> Printf.sprintf "  %-*s  %s" widest name d
              | None -> "  " ^ name)
            items
        in
        let shown =
          if List.length shown > 40 then
            List.filteri (fun i _ -> i < 40) shown
            @ [ Printf.sprintf "  ... and %d more" (List.length shown - 40) ]
          else shown
        in
        write ("\r\n" ^ String.concat "\r\n" shown ^ "\r\n");
        rows_up := 0;
        rows_total := 1;
        buf
      end
  in
  let read complete initial =
    let buf = if initial = "" then empty_buffer else buffer_of initial in
    columns := terminal_columns ();
    with_raw (fun () ->
        rows_up := 0;
        rows_total := 1;
        draw buf;
        let rec loop buf live index =
          wait_for_key buf;
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
                    | "tab" -> (tab complete buf, live, index)
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
    `idle` runs before each line is read.
    (() -> ()) -> reader *)
let pipe_reader idle =
  let read _complete _initial =
    read_entry (fun shown ->
        idle ();
        print_string shown;
        flush stdout;
        match input_line stdin with
        | line -> Some line
        | exception End_of_file -> None)
  in
  { read; ask = (fun _ -> "cancel"); interactive = false }

(** An editor if stdin is a terminal, a pipe reader otherwise. `idle`
    lets a plugin answer what is waiting for it.
    (() -> ()) -> reader *)
let make_reader idle =
  if Unix.isatty Unix.stdin then editor complete next_indent idle
  else pipe_reader idle

(* --- the terminal session --- *)

(** The session's host in a terminal: lines to standard output, and a
    module implemented in a target language reached through its OCaml
    plugin (plugin_host.ml), loaded as it is imported. Repl_session.host *)
let terminal_host =
  {
    write = print_endline;
    machine =
      (function
      | None -> Interpreter.console_host
      | Some externals ->
          Interpreter.callback_host ~externals (fun line ->
              print_string line;
              print_newline ()));
    connect =
      (fun added all ->
        let plugins units =
          List.filter_map
            (fun (unit : Module.t) ->
              match unit.declaration_path with
              | Some declaration_path ->
                  Some
                    Plugin_host.
                      {
                        name = unit.name;
                        declared = Module.external_signatures unit.declarations;
                        declaration_path;
                      }
              | None -> None)
            units
        in
        Plugin_host.load (plugins added);
        Plugin_host.externals (plugins all));
    from = None;
  }


(** An outcome that leaves nothing in the prompt. session -> outcome *)
let plain session = { out_session = session; pending = "" }

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

(** The prompt shown when a def names something not yet defined.
    string -> string *)
let undefined_message name =
  Printf.sprintf
    "Identifier '%s' is not yet defined. Press <esc> to cancel or <space> to \
     continue editing."
    name

let quit_commands = [ ":quit"; ":q" ]

(** Runs the REPL loop until end of input or `:quit`. `format_error` is
    the driver's (pyk.ml). (exn -> string option) -> int *)
let start ?read ?session ?(libs = []) format_error =
  let report error =
    match format_error error with
    | Some text -> prerr_endline text
    | None -> raise error
  in
  (* What a plugin does while the prompt waits -- a callback a page's
     event reached -- is reported like an entry's own mistakes. *)
  let idle () = try Pyk_plugin.run_idle () with error -> report error in
  let reader = match read with Some reader -> reader | None -> make_reader idle in
  print_endline banner;
  let rec loop session pending =
    match reader.read (completions ~terminal:true session) pending with
    | None ->
        print_newline ();
        0
    | Some source -> (
        let line = String.trim source in
        if line = "" then loop session ""
        else if List.mem line quit_commands then 0
        else if starts_with ":" line then
          let outcome = run_meta ~extra:[ (":load", meta_load) ] session line report in
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
  loop
    (match session with Some session -> session | None -> new_session ~libs terminal_host)
    ""
