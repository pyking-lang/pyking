(** `pyk ai`: what a coding assistant reads to write Pyking, printed
    where it can read it, or put in a project for it.

    `make` writes the files into share/help/ai/ (tools/help/aidoc.py):
    the short guide PYKING-LLM.md, the full reference PYKING.md, the
    AGENTS.md a project starts from, and the standard library as plain
    text, lib/NAME.md short and lib/NAME.full.md in full, where NAME is
    a module or a submodule (`tinyweb.color`). This module only reads
    them, so `pyk ai` always says what the pyk it comes with accepts.

    Functions:
      run argv -- runs `pyk ai ...`, answering the exit code. *)

let usage =
  "Usage: pyk ai init [<dir>]        put AGENTS.md, CLAUDE.md and PYKING-LLM.md\n\
  \                                  in a project (default: this directory)\n\
  \       pyk ai guide               print PYKING-LLM.md, the short guide\n\
  \       pyk ai lib                 list the standard library\n\
  \       pyk ai lib <name>          what a library exports, one line each\n\
  \                                  (pyk ai lib text, pyk ai lib tinyweb.color)\n\
  \       pyk ai lib <name> --full   the same, in full, with examples\n\
  \       pyk ai lib <name>.<item>   one export in full (pyk ai lib text.split)\n\
  \       pyk ai lib <item>          every export of that name (pyk ai lib fmap)\n\
  \       pyk ai ref                 list the language reference's sections\n\
  \       pyk ai ref <words>         print the sections whose titles hold the\n\
  \                                  words (pyk ai ref match, pyk ai ref loop)\n\n\
   Everything is plain Markdown on standard output, written for a coding\n\
   assistant -- a language model in a harness such as opencode or Claude\n\
   Code -- to read. See https://pyking.org/documentation/ai/."

exception Refused of string

let refuse message = raise (Refused message)

(** Where the files are: share/help/ai/ beside the executable.
    () -> string *)
let directory () =
  List.fold_left Filename.concat (Install.root ()) [ "share"; "help"; "ai" ]

(** A file of share/help/ai/, by its path below it. string -> string *)
let read name =
  let path = Filename.concat (directory ()) name in
  try Module.read_whole_file path
  with Sys_error _ ->
    refuse
      (Printf.sprintf
         "%s is missing: `make` in the repository writes it, and a distribution ships it" path)

let lines text = String.split_on_char '\n' text

(** A Markdown heading's level and title, outside code: `## Title` is
    (2, "Title"). string -> (int * string) option *)
let heading line =
  let n = String.length line in
  let rec hashes i = if i < n && line.[i] = '#' then hashes (i + 1) else i in
  let level = hashes 0 in
  if level >= 1 && level < n && line.[level] = ' ' then
    Some (level, String.trim (String.sub line level (n - level)))
  else None

let is_fence line =
  let line = String.trim line in
  String.length line >= 3 && String.sub line 0 3 = "```"

(** A Markdown text as its lines, each with the heading it is, if any:
    a `#` inside a code block is not one. string -> (string * (int *
    string) option) list *)
let headed text =
  let rec go inside acc = function
    | [] -> List.rev acc
    | line :: rest ->
        if is_fence line then go (not inside) ((line, None) :: acc) rest
        else go inside ((line, if inside then None else heading line) :: acc) rest
  in
  go false [] (lines text)

(** The sections of a text whose heading `wanted` accepts: each from its
    heading to the next heading of its level or above. With `~brief`, a
    section stops at its first subheading instead, and lists the
    subsections it has. (int -> string -> bool) -> string -> string list *)
let sections ?(brief = false) wanted text =
  let rows = Array.of_list (headed text) in
  let count = Array.length rows in
  let found = ref [] in
  Array.iteri
    (fun i (line, head) ->
      match head with
      | Some (level, title) when wanted level title ->
          let rec stop j =
            if j >= count then j
            else
              match snd rows.(j) with
              | Some (l, _) when l <= level || brief -> j
              | _ -> stop (j + 1)
          in
          let last = stop (i + 1) in
          let body = List.init (last - i - 1) (fun k -> fst rows.(i + 1 + k)) in
          let rec below j acc =
            if j >= count then List.rev acc
            else
              match snd rows.(j) with
              | Some (l, _) when l <= level -> List.rev acc
              | Some (l, t) when l = level + 1 -> below (j + 1) (t :: acc)
              | _ -> below (j + 1) acc
          in
          let subsections = if brief then below (i + 1) [] else [] in
          let text = String.concat "\n" (line :: body) in
          let text =
            match subsections with
            | [] -> String.trim text
            | titles ->
                String.trim text
                ^ "\n\nIts sections, each printed by `pyk ai ref <title>`:\n"
                ^ String.concat "\n" (List.map (fun t -> "- " ^ t) titles)
          in
          found := text :: !found
      | _ -> ())
    rows;
  List.rev !found

let lowercase = String.lowercase_ascii

(** A title without its backticks and in lowercase, as words are
    matched against it. string -> string *)
let plain title =
  lowercase (String.concat "" (String.split_on_char '`' title))

let contains haystack needle =
  let n = String.length needle and h = String.length haystack in
  let rec at i = i + n <= h && (String.sub haystack i n = needle || at (i + 1)) in
  n = 0 || at 0

(* --- pyk ai ref --- *)

(** Every heading of the reference, indented by its level, below the
    title. string -> string *)
let reference_outline text =
  headed text
  |> List.filter_map (fun (_, head) ->
         match head with
         | Some (level, title) when level >= 2 && level <= 3 ->
             Some (String.make (2 * (level - 2)) ' ' ^ "- " ^ title)
         | _ -> None)
  |> String.concat "\n"

let command_ref words =
  let text = read "PYKING.md" in
  match words with
  | [] ->
      print_endline
        "# The language reference\n\n\
         `pyk ai ref <words>` prints the sections whose titles hold the words.\n";
      print_endline (reference_outline text);
      0
  | words ->
      let words = List.map lowercase words in
      let wanted level title =
        level >= 2 && List.for_all (fun w -> contains (plain title) w) words
      in
      let titles =
        headed text
        |> List.filter_map (fun (_, head) ->
               match head with Some (l, t) when wanted l t -> Some t | _ -> None)
      in
      (match titles with
      | [] ->
          refuse
            (Printf.sprintf
               "no section's title holds '%s'; `pyk ai ref` lists them all, and `pyk ai \
                guide` is the short guide"
               (String.concat " " words))
      | titles when List.length titles > 6 ->
          Printf.printf
            "%d sections' titles hold '%s'. Name one of them more closely:\n\n%s\n"
            (List.length titles) (String.concat " " words)
            (String.concat "\n" (List.map (fun t -> "- " ^ t) titles))
      | _ -> print_endline (String.concat "\n\n" (sections ~brief:true wanted text)));
      0

(* --- pyk ai lib --- *)

(** The libraries and submodules there are pages for: lib/NAME.md.
    () -> string list *)
let parts () =
  let lib = Filename.concat (directory ()) "lib" in
  match Sys.readdir lib with
  | exception Sys_error _ -> refuse (Printf.sprintf "%s is missing: `make` in the repository writes it" lib)
  | files ->
      Array.to_list files
      |> List.filter_map (fun file ->
             if Filename.check_suffix file ".full.md" || file = "index.md" then None
             else if Filename.check_suffix file ".md" then Some (Filename.chop_suffix file ".md")
             else None)
      |> List.sort compare

(** The part a name stands for: itself, or a submodule of that name
    (`color` for `tinyweb.color`). string -> string option *)
let find_part name =
  let all = parts () in
  if List.mem name all then Some name
  else
    List.find_opt
      (fun part ->
        let suffix = "." ^ name in
        let n = String.length suffix and p = String.length part in
        p > n && String.sub part (p - n) n = suffix)
      all

(** Whether a heading names an item: itself, or with a qualifier in
    front of it (`int::sort` for `sort`). string -> string -> bool *)
let names_item item title =
  title = item
  ||
  let suffix = "::" ^ item in
  let n = String.length suffix and t = String.length title in
  t > n && String.sub title (t - n) n = suffix

(** One part's exports named item, in full, under the part's import
    line. string -> string -> string option *)
let item_in part item =
  let text = read (Printf.sprintf "lib/%s.full.md" part) in
  match sections (fun level title -> level = 2 && names_item item title) text with
  | [] -> None
  | found ->
      let intro =
        headed text
        |> List.fold_left
             (fun (acc, stopped) (line, head) ->
               if stopped then (acc, true)
               else match head with Some (2, _) -> (acc, true) | _ -> (line :: acc, false))
             ([], false)
        |> fst |> List.rev |> String.concat "\n" |> String.trim
      in
      Some (intro ^ "\n\n" ^ String.concat "\n\n" found)

(** Every export's name, for a "did you mean". () -> string list *)
let item_names () =
  List.concat_map
    (fun part ->
      headed (read (Printf.sprintf "lib/%s.full.md" part))
      |> List.filter_map (fun (_, head) ->
             match head with Some (2, title) -> Some (part ^ "." ^ title) | _ -> None))
    (parts ())

(** The signature of each export in a full page: the first line of the
    code block after its `##` heading. string -> string list *)
let signatures text =
  let rec go acc = function
    | (_, Some (2, _)) :: ("```", _) :: (signature, _) :: rest -> go (signature :: acc) rest
    | _ :: rest -> go acc rest
    | [] -> List.rev acc
  in
  go [] (List.filter (fun (line, _) -> String.trim line <> "") (headed text))

let not_found name =
  let candidates = parts () @ item_names () in
  let close = Suggest.closest name candidates in
  refuse
    (Printf.sprintf "there is no library or export '%s'%s; `pyk ai lib` lists the libraries" name
       (match close with [] -> "" | c :: _ -> Printf.sprintf " (did you mean '%s'?)" c))

let command_lib args =
  let full = List.mem "--full" args in
  let names = List.filter (fun a -> a <> "--full") args in
  (match names with
  | [] -> print_string (read "lib/index.md")
  | [ name ] -> (
      match find_part name with
      | Some part ->
          print_string (read (Printf.sprintf "lib/%s%s.md" part (if full then ".full" else "")))
      | None -> (
          let at = String.rindex_opt name '.' in
          let inside =
            match at with
            | Some i -> (
                let module_name = String.sub name 0 i
                and item = String.sub name (i + 1) (String.length name - i - 1) in
                match find_part module_name with
                | Some part -> (
                    match item_in part item with
                    | Some text -> Some text
                    | None ->
                        refuse
                          (Printf.sprintf "'%s' exports no '%s'; `pyk ai lib %s` lists what it does"
                             part item part))
                | None -> None)
            | None -> None
          in
          match inside with
          | Some text -> print_endline text
          | None -> (
              (* A bare name: the export of that name, in full where one
                 library has it, and where several do, a line on each. *)
              let found =
                List.filter_map
                  (fun part -> Option.map (fun text -> (part, text)) (item_in part name))
                  (parts ())
              in
              match found with
              | [] -> not_found name
              | [ (_, text) ] -> print_endline text
              | found ->
                  Printf.printf
                    "Several libraries export '%s'. `pyk ai lib <library>.%s` shows one in \
                     full:\n\n"
                    name name;
                  List.iter
                    (fun (part, text) ->
                      Printf.printf "- %s:\n%s\n" part
                        (String.concat "\n" (List.map (fun l -> "    " ^ l) (signatures text))))
                    found)))
  | _ -> refuse "'pyk ai lib' takes one name at most");
  0

(* --- pyk ai init --- *)

(** Writes text to path. string -> string -> unit *)
let write path text =
  match open_out_bin path with
  | exception Sys_error message -> refuse message
  | channel ->
      output_string channel text;
      close_out channel

let command_init args =
  let target =
    match args with
    | [] -> "."
    | [ dir ] -> dir
    | _ -> refuse "'pyk ai init' takes one directory at most"
  in
  if not (Sys.file_exists target && Sys.is_directory target) then
    refuse (Printf.sprintf "there is no directory '%s'" target);
  let path name = Filename.concat target name in
  let existing name = try Some (Module.read_whole_file (path name)) with Sys_error _ -> None in
  let guide = read "PYKING-LLM.md" in
  (match existing "PYKING-LLM.md" with
  | Some text when text = guide -> print_endline "PYKING-LLM.md is up to date."
  | Some _ ->
      write (path "PYKING-LLM.md") guide;
      print_endline "PYKING-LLM.md updated to this pyk's version."
  | None ->
      write (path "PYKING-LLM.md") guide;
      print_endline "PYKING-LLM.md written: the short guide to Pyking.");
  (match existing "AGENTS.md" with
  | Some text when contains text "PYKING-LLM.md" -> print_endline "AGENTS.md kept as it is."
  | Some _ ->
      print_endline
        "AGENTS.md kept as it is. It does not mention PYKING-LLM.md: add a line telling the\n\
         assistant to read PYKING-LLM.md before it writes any Pyking."
  | None ->
      write (path "AGENTS.md") (read "AGENTS.md");
      print_endline "AGENTS.md written: opencode, Codex, Cursor and others read it.");
  (match existing "CLAUDE.md" with
  | Some text when contains text "AGENTS.md" || contains text "PYKING-LLM.md" ->
      print_endline "CLAUDE.md kept as it is."
  | Some _ ->
      print_endline
        "CLAUDE.md kept as it is. Add the line `@AGENTS.md` to it, so that Claude Code\n\
         reads AGENTS.md too."
  | None ->
      write (path "CLAUDE.md") "@AGENTS.md\n";
      print_endline "CLAUDE.md written: Claude Code reads AGENTS.md through it.");
  print_endline
    "\nStart your assistant in this directory. It is told to read PYKING-LLM.md, to check\n\
     every change with `pyk check`, and to look libraries up with `pyk ai lib`.";
  0

let run argv =
  try
    match argv with
    | [] | ("--help" | "-h" | "help") :: _ ->
        print_endline usage;
        0
    | "init" :: rest -> command_init rest
    | "guide" :: [] ->
        print_string (read "PYKING-LLM.md");
        0
    | "lib" :: rest -> command_lib rest
    | "ref" :: rest -> command_ref rest
    | word :: _ ->
        refuse
          (Printf.sprintf "there is no 'pyk ai %s'; `pyk ai` lists what there is" word)
  with Refused message ->
    prerr_endline ("pyk ai: " ^ message ^ ".");
    1
