(** Pyking source as coloured text that stays text: `pyk highlight` and
    the browser's `pykHighlight`. The source is cut into spans by the
    compiler's own lexer, one line at a time, so the colours follow the
    real language; each span is given a class the way the playground's
    Monaco tokenizer (tools/webrun/assets/pyking-monaco.js) gives one,
    and coloured with that file's `pyking-light` or `pyking-dark`
    theme. The same spans are then written as an HTML fragment with
    every style inline, as an RTF document, or as plain text. See
    highlight.mli and docs/source.md ("highlight.ml").

    Data structures:
      kind / span / line -- the source, classified.
      theme / background / spaces / options -- how it is written.
      palette -- a theme's colours.
      block / piece -- a notebook's Pyking blocks, and its prose.

    Functions:
      classify source -- the source's lines, as spans.
      html / rtf / text options source -- one snippet in one format.
      rtf_document / text_document / html_snippets -- several.
      notebook_pieces / notebook_blocks -- a notebook's blocks.
      marked_markdown / fill_markers -- a whole notebook as HTML.
      parse_* / options_of_json -- options, as they are written. *)

type kind =
  | Keyword
  | Type
  | Constant
  | Number
  | String
  | Comment
  | Function
  | Builtin
  | Operator
  | Plain

type span = { kind : kind; text : string }
type line = { indent : int; spans : span list }

let kind_name = function
  | Keyword -> "keyword"
  | Type -> "type"
  | Constant -> "constant"
  | Number -> "number"
  | String -> "string"
  | Comment -> "comment"
  | Function -> "function"
  | Builtin -> "builtin"
  | Operator -> "operator"
  | Plain -> "plain"

let kinds = [ Keyword; Type; Constant; Number; String; Comment; Function; Builtin; Operator; Plain ]

(* --- classifying --- *)

(** Whether a word starts with a capital letter. string -> bool *)
let capitalised word = word <> "" && word.[0] >= 'A' && word.[0] <= 'Z'

(** The tokens that are punctuation rather than operators: what
    pyking-monaco.js calls brackets and delimiters, and leaves
    uncoloured. *)
let punctuation = [ "("; ")"; "["; "]"; "{"; "}"; ","; ":"; "." ]

(** A token's kind, from the token, its text and whether the token
    before it was `def`. Lexer.token -> string -> bool -> kind *)
let token_kind (token : Lexer.token) text after_def =
  match token with
  | TokInt _ | TokFloat _ -> Number
  | TokString _ | TokChar _ -> String
  | TokIdent (_, name) ->
      if after_def then Function
      else if capitalised name then Type
      else if List.mem name Builtin.names then Builtin
      else Plain
  | _ when List.mem text Lexer.keywords ->
      if capitalised text then Type
      else if text = "true" || text = "false" then Constant
      else Keyword
  | _ when List.mem text punctuation -> Plain
  | _ -> Operator

(** Every non-breaking space in a string of spaces as an ordinary
    one. string -> string *)
let ordinary_spaces s =
  let b = Buffer.create (String.length s) in
  let n = String.length s in
  let rec go i =
    if i < n then
      if i + 1 < n && s.[i] = '\xC2' && s.[i + 1] = '\xA0' then (
        Buffer.add_char b ' ';
        go (i + 2))
      else (
        Buffer.add_char b s.[i];
        go (i + 1))
  in
  go 0;
  Buffer.contents b

(** The text between two tokens, or after the last: spaces, and a `#`
    comment to the end of the line. string -> [span] *)
let gap_spans text =
  if text = "" then []
  else
    match String.index_opt text '#' with
    | None -> [ { kind = Plain; text = ordinary_spaces text } ]
    | Some i ->
        let before = String.sub text 0 i in
        let comment = String.sub text i (String.length text - i) in
        (if before = "" then [] else [ { kind = Plain; text = ordinary_spaces before } ])
        @ [ { kind = Comment; text = comment } ]

(** The tokens of the longest prefix of `s` that lexes, and its length:
    the whole of it where it lexes, and otherwise the prefix ending where
    the lexer failed, or at the space before that.
    string -> ([Lexer.token], int) *)
let lexed_prefix s =
  let lex k = Lexer.lexing "" (Lexer.chars_of_string (String.sub s 0 k)) in
  let boundary k =
    (* The last place before k that a token may start: just after a space. *)
    let rec back j = if j <= 0 then 0 else if s.[j - 1] = ' ' then j else back (j - 1) in
    back (k - 1)
  in
  let rec best k =
    if k <= 0 then ([], 0)
    else
      match lex k with
      | tokens -> (tokens, k)
      | exception Lexer.Lex_error (info, _) ->
          let at = info.Lexer.col1 in
          best (if at >= 0 && at < k then at else boundary k)
  in
  best (String.length s)

(** One line, without its leading spaces, as spans. string -> [span] *)
let line_spans s =
  let tokens, stop = lexed_prefix s in
  let rec go tokens at after_def acc =
    match tokens with
    | [] ->
        let rest = gap_spans (String.sub s at (stop - at)) in
        let tail = if stop < String.length s then [ { kind = Plain; text = String.sub s stop (String.length s - stop) } ] else [] in
        List.rev acc @ rest @ tail
    | token :: more ->
        let info = Lexer.token_info token in
        let c1 = info.Lexer.col1 and c2 = info.Lexer.col2 in
        if c2 <= c1 || c1 < at || c2 > stop then go more at after_def acc
        else
          let text = String.sub s c1 (c2 - c1) in
          let kind = token_kind token text after_def in
          let gap = gap_spans (String.sub s at (c1 - at)) in
          let after_def = match token with Lexer.TokDef _ -> true | _ -> false in
          go more c2 after_def ({ kind; text } :: List.rev_append gap acc)
  in
  (* Runs of one kind are one span. *)
  let rec merge = function
    | a :: b :: rest when a.kind = b.kind -> merge ({ a with text = a.text ^ b.text } :: rest)
    | a :: rest -> a :: merge rest
    | [] -> []
  in
  merge (go tokens 0 false [])

(** A line's leading spaces, ordinary or non-breaking: how many, and the
    bytes they take. string -> (int, int) *)
let leading s =
  let n = String.length s in
  let rec go i count =
    if i < n && s.[i] = ' ' then go (i + 1) (count + 1)
    else if i + 1 < n && s.[i] = '\xC2' && s.[i + 1] = '\xA0' then go (i + 2) (count + 1)
    else (count, i)
  in
  go 0 0

(** The source with tabs as four spaces and no carriage returns, as its
    lines, and whether it ends with a newline. string -> ([string], bool) *)
let source_lines source =
  let b = Buffer.create (String.length source) in
  String.iter
    (fun c -> match c with '\t' -> Buffer.add_string b "    " | '\r' -> () | c -> Buffer.add_char b c)
    source;
  let text = Buffer.contents b in
  let ends = text <> "" && text.[String.length text - 1] = '\n' in
  let lines = String.split_on_char '\n' text in
  let lines = if ends then List.rev (List.tl (List.rev lines)) else lines in
  ((if text = "" then [] else lines), ends)

let classify source =
  List.map
    (fun s ->
      let count, bytes = leading s in
      let rest = String.sub s bytes (String.length s - bytes) in
      if rest = "" then { indent = 0; spans = [] } else { indent = count; spans = line_spans rest })
    (fst (source_lines source))

(* --- options --- *)

type theme = Light | Dark
type background = No_background | Theme_background | Colour of string
type spaces = Indent | All | Ordinary

type options = {
  theme : theme;
  font : string;
  size : int option;
  background : background;
  spaces : spaces;
}

let default_options =
  { theme = Light; font = "Menlo"; size = None; background = No_background; spaces = Indent }

let parse_theme name = function
  | "light" -> Ok Light
  | "dark" -> Ok Dark
  | given -> Error (Printf.sprintf "%s is light or dark, not '%s'" name given)

let parse_font name given =
  let fine c =
    match c with 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | ' ' | '-' | '_' | '.' -> true | _ -> false
  in
  if String.trim given <> "" && String.for_all fine given then Ok (String.trim given)
  else
    Error
      (Printf.sprintf "%s names a font in letters, digits, spaces, '-', '_' and '.', not '%s'" name given)

let parse_size name given =
  match int_of_string_opt (String.trim given) with
  | Some n when n >= 1 && n <= 1000 && String.for_all (fun c -> c >= '0' && c <= '9') (String.trim given) -> Ok n
  | _ -> Error (Printf.sprintf "%s is a whole number of points from 1 to 1000, not '%s'" name given)

let is_hex c = match c with '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true | _ -> false

let parse_background name = function
  | "none" -> Ok No_background
  | "theme" -> Ok Theme_background
  | given when String.length given = 7 && given.[0] = '#' && String.for_all is_hex (String.sub given 1 6) ->
      Ok (Colour (String.lowercase_ascii given))
  | given -> Error (Printf.sprintf "%s is none, theme or a colour #rrggbb, not '%s'" name given)

let parse_spaces name = function
  | "indent" -> Ok Indent
  | "all" -> Ok All
  | "none" -> Ok Ordinary
  | given -> Error (Printf.sprintf "%s is indent, all or none, not '%s'" name given)

let options_of_json value =
  let ( let* ) = Result.bind in
  match value with
  | Json.Null -> Ok default_options
  | Json.Object fields ->
      let known = [ "theme"; "font"; "size"; "background"; "spaces" ] in
      let* () =
        match List.find_opt (fun (k, _) -> not (List.mem k known)) fields with
        | Some (k, _) ->
            Error (Printf.sprintf "highlight has no option '%s'; it takes theme, font, size, background and spaces" k)
        | None -> Ok ()
      in
      let field name parse set options =
        match List.assoc_opt name fields with
        | None | Some Json.Null -> Ok options
        | Some (Json.String s) -> Result.map (set options) (parse name s)
        | Some (Json.Number f) when name = "size" ->
            let written = if Float.is_integer f then Printf.sprintf "%.0f" f else Printf.sprintf "%g" f in
            Result.map (set options) (parse name written)
        | Some _ ->
            Error (Printf.sprintf "%s is a string%s" name (if name = "size" then " or a number" else ""))
      in
      let options = default_options in
      let* options = field "theme" parse_theme (fun o v -> { o with theme = v }) options in
      let* options = field "font" parse_font (fun o v -> { o with font = v }) options in
      let* options = field "size" parse_size (fun o v -> { o with size = Some v }) options in
      let* options = field "background" parse_background (fun o v -> { o with background = v }) options in
      let* options = field "spaces" parse_spaces (fun o v -> { o with spaces = v }) options in
      Ok options
  | _ -> Error "the options are an object: {theme, font, size, background, spaces}"

(* --- colours --- *)

type palette = {
  foreground : string;
  background_colour : string;
  colour : kind -> string option;
  italic : kind -> bool;
}

(* The colours of pyking-monaco.js's two themes, Tomorrow and Tomorrow
   Night: each theme's seven colours, and which of them each kind takes
   there (a constant a number's, an operator a builtin's).
   tests/test_highlight.py reads that file to keep these the same. *)
let palette theme =
  let comment, string, number, keyword, type_, function_, builtin, fg, bg =
    match theme with
    | Light -> ("#8e908c", "#718c00", "#f5871f", "#8959a8", "#c99e00", "#4271ae", "#3e999f", "#4d4d4c", "#ffffff")
    | Dark -> ("#969896", "#b5bd68", "#de935f", "#b294bb", "#f0c674", "#81a2be", "#8abeb7", "#c5c8c6", "#1d1f21")
  in
  let colour = function
    | Comment -> Some comment
    | String -> Some string
    | Number | Constant -> Some number
    | Keyword -> Some keyword
    | Type -> Some type_
    | Function -> Some function_
    | Builtin | Operator -> Some builtin
    | Plain -> None
  in
  { foreground = fg; background_colour = bg; colour; italic = (fun k -> k = Comment) }

(** The background an options asks for, if any. options -> string? *)
let background_of options =
  match options.background with
  | No_background -> None
  | Theme_background -> Some (palette options.theme).background_colour
  | Colour c -> Some c

(* --- spaces --- *)

let nbsp = "\xC2\xA0"

(** A span's text with every space as U+00A0 where `all` is asked for.
    A String or Char literal keeps its spaces as written, since they are
    part of what the program prints. spaces -> string -> string *)
let spaced spaces text =
  if spaces <> All then text
  else
    let b = Buffer.create (String.length text) in
    String.iter (fun c -> if c = ' ' then Buffer.add_string b nbsp else Buffer.add_char b c) text;
    Buffer.contents b

(** A line's indentation as the options write it. spaces -> int -> string *)
let indentation spaces count =
  if spaces = Ordinary then String.make count ' '
  else String.concat "" (List.init count (fun _ -> nbsp))

(** A line's spans with its indentation in front, as a Plain span, and
    `spaces` applied. spaces -> line -> [span] *)
let laid_out spaces line =
  let indent = if line.indent > 0 then [ { kind = Plain; text = indentation spaces line.indent } ] else [] in
  indent @ List.map (fun s -> if s.kind = String then s else { s with text = spaced spaces s.text }) line.spans

(** Source shown as it is, every line one Plain span: an output block.
    string -> [line] *)
let plain_lines source =
  List.map
    (fun s ->
      let count, bytes = leading s in
      let rest = String.sub s bytes (String.length s - bytes) in
      if rest = "" then { indent = 0; spans = [] } else { indent = count; spans = [ { kind = Plain; text = rest } ] })
    (fst (source_lines source))

(* --- plain text --- *)

let text_lines options lines =
  String.concat "\n"
    (List.map (fun l -> String.concat "" (List.map (fun s -> s.text) (laid_out options.spaces l))) lines)

let text options source =
  let lines = classify source in
  let ends = snd (source_lines source) in
  let body = text_lines options lines in
  if ends && lines <> [] then body ^ "\n" else body

(* --- HTML --- *)

(** Text made safe in HTML, every character outside ASCII a character
    reference and U+00A0 `&nbsp;`. string -> string *)
let escape_html s =
  let b = Buffer.create (String.length s) in
  List.iter
    (fun cp ->
      match cp with
      | 0x26 -> Buffer.add_string b "&amp;"
      | 0x3C -> Buffer.add_string b "&lt;"
      | 0x3E -> Buffer.add_string b "&gt;"
      | 0x22 -> Buffer.add_string b "&quot;"
      | 0xA0 -> Buffer.add_string b "&nbsp;"
      | cp when cp < 0x80 -> Buffer.add_char b (Char.chr cp)
      | cp -> Buffer.add_string b (Printf.sprintf "&#%d;" cp))
    (Builtin.code_points s);
  Buffer.contents b

(** The pre's style attribute's value. options -> string *)
let pre_style options =
  let p = palette options.theme in
  String.concat ";"
    ([ Printf.sprintf "font-family:'%s',monospace" options.font; "white-space:pre"; "color:" ^ p.foreground ]
    @ (match background_of options with Some c -> [ "background:" ^ c ] | None -> [])
    @ match options.size with Some n -> [ Printf.sprintf "font-size:%dpt" n ] | None -> [])

let html_span palette span =
  match palette.colour span.kind with
  | None -> escape_html span.text
  | Some c ->
      Printf.sprintf "<span style=\"color:%s%s\">%s</span>" c
        (if palette.italic span.kind then ";font-style:italic" else "")
        (escape_html span.text)

let html_lines options lines =
  let p = palette options.theme in
  Printf.sprintf "<pre style=\"%s\">%s</pre>" (pre_style options)
    (String.concat "\n"
       (List.map (fun l -> String.concat "" (List.map (html_span p) (laid_out options.spaces l))) lines))

let html options source = html_lines options (classify source)

(* --- RTF --- *)

(** Text made safe in RTF: `\`, `{` and `}` escaped, U+00A0 `\~`, and
    every other character outside ASCII `\uN?`, a surrogate pair past
    U+FFFF. string -> string *)
let escape_rtf s =
  let b = Buffer.create (String.length s) in
  let unit n = Buffer.add_string b (Printf.sprintf "\\u%d?" (if n >= 0x8000 then n - 0x10000 else n)) in
  List.iter
    (fun cp ->
      match cp with
      | 0x5C -> Buffer.add_string b "\\\\"
      | 0x7B -> Buffer.add_string b "\\{"
      | 0x7D -> Buffer.add_string b "\\}"
      | 0xA0 -> Buffer.add_string b "\\~"
      | cp when cp < 0x80 -> Buffer.add_char b (Char.chr cp)
      | cp when cp > 0xFFFF ->
          let v = cp - 0x10000 in
          unit (0xD800 lor (v lsr 10));
          unit (0xDC00 lor (v land 0x3FF))
      | cp -> unit cp)
    (Builtin.code_points s);
  Buffer.contents b

(** The colour table's colours, the text's first and the background's
    second where there is one, each once. options -> [string] *)
let rtf_colours options =
  let p = palette options.theme in
  let all =
    [ p.foreground ]
    @ (match background_of options with Some c -> [ c ] | None -> [])
    @ List.filter_map p.colour kinds
  in
  List.fold_left (fun acc c -> if List.mem c acc then acc else acc @ [ c ]) [] all

(** A colour's index in the table, counted from 1 (0 is "auto").
    [string] -> string -> int *)
let rtf_index colours c =
  let rec find i = function [] -> 1 | x :: rest -> if x = c then i else find (i + 1) rest in
  find 1 colours

let rtf_component hex at = int_of_string ("0x" ^ String.sub hex at 2)

(** The document's header: fonts and colours, then the paragraph's
    defaults. options -> [string] -> string *)
let rtf_header options colours =
  let table =
    String.concat ""
      (List.map
         (fun c ->
           Printf.sprintf "\\red%d\\green%d\\blue%d;" (rtf_component c 1) (rtf_component c 3) (rtf_component c 5))
         colours)
  in
  Printf.sprintf
    "{\\rtf1\\ansi\\ansicpg1252\\deff0\\uc1\n{\\fonttbl{\\f0\\fmodern\\fcharset0 %s;}{\\f1\\fswiss\\fcharset0 Helvetica;}}\n{\\colortbl;%s}\n"
    options.font table

(** The control words that start a code paragraph: the font, size,
    colour and background. options -> [string] -> string *)
let rtf_code_start options colours =
  Printf.sprintf "\\pard\\plain\\f0%s\\cf1%s "
    (match options.size with Some n -> Printf.sprintf "\\fs%d" (2 * n) | None -> "")
    (match background_of options with Some c -> Printf.sprintf "\\cb%d" (rtf_index colours c) | None -> "")

let rtf_span palette colours span =
  match palette.colour span.kind with
  | None -> escape_rtf span.text
  | Some c ->
      Printf.sprintf "{\\cf%d%s %s}" (rtf_index colours c)
        (if palette.italic span.kind then "\\i" else "")
        (escape_rtf span.text)

(** A snippet's lines as RTF: a paragraph each. options -> [string] ->
    [line] -> string *)
let rtf_lines options colours lines =
  let p = palette options.theme in
  rtf_code_start options colours
  ^ String.concat "\\par\n"
      (List.map (fun l -> String.concat "" (List.map (rtf_span p colours) (laid_out options.spaces l))) lines)

let rtf options source =
  let colours = rtf_colours options in
  rtf_header options colours ^ rtf_lines options colours (classify source) ^ "}\n"

(* --- notebooks --- *)

type block = { number : int; info : string; source : string }
type piece = Prose of string | Code of block | Output of string

let pyking_languages = [ "pyking"; "pyk" ]
let output_languages = [ "stdin"; "stdout"; "stderr" ]

(** Text without a front matter block at its start: `---`, then lines,
    then `---` or `...`. string -> string *)
let without_front_matter text =
  let lines = String.split_on_char '\n' text in
  let fence l = let t = String.trim l in t = "---" in
  match lines with
  | first :: rest when fence first ->
      let rec skip = function
        | [] -> None
        | l :: more -> let t = String.trim l in if t = "---" || t = "..." then Some more else skip more
      in
      (match skip rest with Some more -> String.concat "\n" more | None -> text)
  | _ -> text

let notebook_pieces markdown =
  let pieces = Notebook_format.scan markdown in
  let count = ref 0 in
  List.filter_map
    (fun piece ->
      match piece with
      | Notebook_format.Text t -> Some (Prose t)
      | Notebook_format.Fence f when List.mem f.language pyking_languages ->
          incr count;
          Some (Code { number = !count; info = String.trim f.info; source = f.body })
      | Notebook_format.Fence f when List.mem f.language output_languages -> Some (Output f.body)
      | Notebook_format.Fence _ -> None)
    pieces

let notebook_blocks markdown =
  List.filter_map (function Code b -> Some b | _ -> None) (notebook_pieces markdown)

(** Whether a line of Markdown starts a line of its own however it is
    wrapped: a list item, a heading, a quote or a table row.
    string -> bool *)
let starts_line l =
  let t = String.trim l in
  let n = String.length t in
  n > 0
  && (List.mem t.[0] [ '#'; '>'; '|' ]
     || (n > 1 && List.mem t.[0] [ '-'; '*'; '+' ] && t.[1] = ' ')
     ||
     let rec digits i = if i < n && t.[i] >= '0' && t.[i] <= '9' then digits (i + 1) else i in
     let i = digits 0 in
     i > 0 && i + 1 < n && (t.[i] = '.' || t.[i] = ')') && t.[i + 1] = ' ')

(** The prose as paragraphs, each a run of lines between blank lines,
    and each paragraph's lines: a wrapped line joined to the one before
    it by a space, and a list item, heading, quote or table row a line
    of its own. string -> [[string]] *)
let paragraphs text =
  let lines = String.split_on_char '\n' (String.concat "" (String.split_on_char '\r' text)) in
  let close current acc = if current = [] then acc else List.rev current :: acc in
  let rec go current acc = function
    | [] -> List.rev (close current acc)
    | l :: rest when String.trim l = "" -> go [] (close current acc) rest
    | l :: rest -> (
        let l = String.trim l in
        match current with
        | last :: before when not (starts_line l) -> go ((last ^ " " ^ l) :: before) acc rest
        | _ -> go (l :: current) acc rest)
  in
  go [] [] lines

(** A piece's lines, as a snippet shows them, or None for prose.
    piece -> [line]? *)
let piece_lines = function
  | Code b -> Some (classify b.source)
  | Output text -> Some (plain_lines text)
  | Prose _ -> None

(** The pieces with a front matter block left out of the prose it
    starts. [piece] -> [piece] *)
let as_read = function Prose t :: rest -> Prose (without_front_matter t) :: rest | pieces -> pieces

let rtf_document options pieces =
  let pieces = as_read pieces in
  let colours = rtf_colours options in
  let parts =
    List.concat_map
      (fun piece ->
        match piece_lines piece with
        | Some lines -> [ rtf_lines options colours lines ]
        | None ->
            List.map
              (fun lines ->
                Printf.sprintf "\\pard\\plain\\f1%s\\cf1 %s"
                  (match options.size with Some n -> Printf.sprintf "\\fs%d" (2 * n) | None -> "")
                  (String.concat "\\line\n" (List.map escape_rtf lines)))
              (paragraphs (match piece with Prose t -> t | _ -> "")))
      pieces
  in
  rtf_header options colours ^ String.concat "\\par\n\\pard\\plain\\par\n" parts ^ "}\n"

let text_document options pieces =
  let pieces = as_read pieces in
  let parts =
    List.filter_map
      (fun piece ->
        match piece_lines piece, piece with
        | Some lines, _ -> Some (text_lines options lines)
        | None, Prose t ->
            let t = String.trim t in
            if t = "" then None else Some t
        | None, _ -> None)
      pieces
  in
  String.concat "\n\n" parts ^ if parts = [] then "" else "\n"

let html_snippets options pieces =
  String.concat "\n"
    (List.filter_map (fun piece -> Option.map (html_lines options) (piece_lines piece)) pieces)
  ^ "\n"

let marker k = Printf.sprintf "<div data-pyk-piece=\"%d\"></div>" k

let marked_markdown pieces =
  String.concat ""
    (List.mapi
       (fun k piece ->
         match piece with
         | Prose t -> t
         | Code _ | Output _ -> "\n" ^ marker k ^ "\n\n")
       pieces)

(** Every occurrence of `find` in `s` replaced. string -> string ->
    string -> string *)
let replace_all find by s =
  let n = String.length find in
  let b = Buffer.create (String.length s) in
  let rec go i =
    if i > String.length s - n then Buffer.add_string b (String.sub s i (String.length s - i))
    else if String.sub s i n = find then (
      Buffer.add_string b by;
      go (i + n))
    else (
      Buffer.add_char b s.[i];
      go (i + 1))
  in
  go 0;
  Buffer.contents b

let fill_markers options pieces html =
  let k = ref (-1) in
  List.fold_left
    (fun html piece ->
      incr k;
      match piece_lines piece with
      | Some lines -> replace_all (marker !k) (html_lines options lines) html
      | None -> html)
    html pieces

let html_page ~title ~style body =
  Printf.sprintf
    "<!doctype html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>%s</title>\n<style>\n%s</style>\n</head>\n<body>\n%s</body>\n</html>\n"
    (escape_html title) style body
