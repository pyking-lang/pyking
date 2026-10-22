(** Notebooks as JSON: a notebook's Markdown read into one structured
    value -- the text between its blocks kept as it is, each exercise
    with its solution, tests and diff-allowed blocks, each quiz with its
    answer, each cell with the tests under it -- and that value written
    back as the same Markdown, character for character. Also the JSON
    Schema such a value follows. The blocks are found and grouped as
    tools/notebook/assets/markdown.js and exercises.js find and group
    them. See docs/notebook.md ("JSON").

    Data structures:
      Format_error -- a JSON value that is not a notebook.
      value -- an attribute's value: a string, a number or a boolean.
      fence -- one notebook block as the Markdown writes it.
      piece -- the text between blocks, or a block.

    Functions:
      of_markdown text -- the notebook text holds, as JSON.
      to_markdown value -- the Markdown a notebook's JSON stands for.
      schema -- the JSON Schema every notebook's JSON follows. *)

exception Format_error of string

type value = VString of string | VNumber of float | VBool of bool

type fence = {
  language : string;  (** lowercased, as written *)
  attrs : (string * value) list;  (** in the order written *)
  info : string;  (** what follows the fence marker on its line *)
  marker : string;  (** the opening ``` or ~~~ *)
  body : string;  (** the lines between, each with its newline *)
  close : string option;  (** the closing line, or None at the end of the text *)
  gap : string option;  (** the blank lines before it, where a block is right before *)
}

type piece = Text of string | Fence of fence

(* --- what a notebook's fence holds --- *)

(** The languages of the blocks a notebook reads. *)
let notebook_languages =
  [ "pyking"; "pyk"; "stdin"; "args"; "stdout"; "stderr"; "events"; "quiz"; "answer"; "rules";
    "diff-allowed" ]

(** The attributes whose value is a number, and those that are true or
    false. *)
let number_keys = [ "max"; "pass"; "attempts"; "points"; "penalty"; "lines_per_multi_input" ]

let bool_keys = [ "available"; "visible"; "one_point_correct" ]

(** The words written bare, standing for themselves. *)
let flag_keys = [ "exercise"; "solution"; "norun"; "readonly"; "error"; "playground" ]

let is_space c = c = ' ' || c = '\t' || c = '\n' || c = '\r' || c = '\011' || c = '\012'

let trim_spaces s =
  let n = String.length s in
  let i = ref 0 and j = ref n in
  while !i < n && is_space s.[!i] do incr i done;
  while !j > !i && is_space s.[!j - 1] do decr j done;
  String.sub s !i (!j - !i)

type word = Equals | Word of string * bool  (** text, and whether it was quoted *)

(** A fence's info string as markdown.js's parseInfo reads it: the
    language, lowercased, and each attribute with its raw value (Some
    text, or None for a bare word). string -> (string, [(string, string?)]) *)
let parse_info info =
  let raw = trim_spaces info in
  let inner =
    let s = if String.length raw > 0 && raw.[0] = '{' then String.sub raw 1 (String.length raw - 1) else raw in
    let n = String.length s in
    if n > 0 && s.[n - 1] = '}' then String.sub s 0 (n - 1) else s
  in
  let n = String.length inner in
  let separator c = is_space c || c = ',' in
  let rec words i acc =
    if i >= n then List.rev acc
    else if separator inner.[i] then words (i + 1) acc
    else if inner.[i] = '=' then words (i + 1) (Equals :: acc)
    else if inner.[i] = '"' || inner.[i] = '\'' then (
      let quote = inner.[i] in
      let buffer = Buffer.create 16 in
      let rec text j =
        if j >= n || inner.[j] = quote then j
        else if inner.[j] = '\\' && j + 1 < n then (
          (match inner.[j + 1] with
          | 'n' -> Buffer.add_char buffer '\n'
          | 't' -> Buffer.add_char buffer '\t'
          | c -> Buffer.add_char buffer c);
          text (j + 2))
        else (
          Buffer.add_char buffer inner.[j];
          text (j + 1))
      in
      let j = text (i + 1) in
      words (j + 1) (Word (Buffer.contents buffer, true) :: acc))
    else
      let rec stop j = if j < n && (not (separator inner.[j])) && inner.[j] <> '=' then stop (j + 1) else j in
      let j = stop i in
      let text = String.sub inner i (j - i) in
      let text = if String.length text > 0 && text.[0] = '.' then String.sub text 1 (String.length text - 1) else text in
      words j (Word (text, false) :: acc)
  in
  let words = Array.of_list (words 0 []) in
  let language =
    if Array.length words > 0 then match words.(0) with Word (t, _) -> String.lowercase_ascii t | Equals -> ""
    else ""
  in
  let set attrs name v =
    if List.mem_assoc name attrs then List.map (fun (k, old) -> if k = name then (k, v) else (k, old)) attrs
    else attrs @ [ (name, v) ]
  in
  let count = Array.length words in
  let rec go k attrs =
    if k >= count then attrs
    else
      match words.(k) with
      | Equals | Word (_, true) -> go (k + 1) attrs
      | Word (text, false) ->
          let name = String.lowercase_ascii text in
          if name = "" then go (k + 1) attrs
          else if k + 2 < count && words.(k + 1) = Equals && words.(k + 2) <> Equals then
            let v = match words.(k + 2) with Word (t, _) -> t | Equals -> "" in
            go (k + 3) (set attrs name (Some v))
          else go (k + 1) (set attrs name None)
  in
  (language, go 1 [])

(** Whether text is a number as an attribute writes one: digits, with a
    sign and a fraction if any. string -> bool *)
let is_number s =
  let n = String.length s in
  let digits i = let j = ref i in while !j < n && s.[!j] >= '0' && s.[!j] <= '9' do incr j done; !j in
  let i = if n > 0 && s.[0] = '-' then 1 else 0 in
  let j = digits i in
  if j = i then false
  else if j = n then true
  else if s.[j] = '.' then let k = digits (j + 1) in k > j + 1 && k = n
  else false

(** An attribute's raw value as a typed one. string -> string? -> value *)
let typed name raw =
  match raw with
  | None -> VBool true
  | Some s when List.mem name number_keys && is_number s -> VNumber (float_of_string s)
  | Some ("true" | "false" as s) when List.mem name bool_keys -> VBool (s = "true")
  | Some s -> VString s

let typed_attrs attrs = List.map (fun (k, raw) -> (k, typed k raw)) attrs

let number_text f =
  if Float.is_integer f && Float.abs f < 1e15 then Printf.sprintf "%.0f" f
  else
    let rec shortest p = let t = Printf.sprintf "%.*g" p f in if p >= 17 || float_of_string t = f then t else shortest (p + 1) in
    shortest 1

let quoted s =
  let buffer = Buffer.create (String.length s + 2) in
  Buffer.add_char buffer '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buffer "\\\""
      | '\\' -> Buffer.add_string buffer "\\\\"
      | '\n' -> Buffer.add_string buffer "\\n"
      | '\t' -> Buffer.add_string buffer "\\t"
      | c -> Buffer.add_char buffer c)
    s;
  Buffer.add_char buffer '"';
  Buffer.contents buffer

(** One attribute as a canonical header writes it. (string, value) -> string *)
let attribute_text (name, v) =
  match v with
  | VBool true when List.mem name flag_keys -> name
  | VBool b -> Printf.sprintf "%s = %b" name b
  | VNumber f -> Printf.sprintf "%s = %s" name (number_text f)
  | VString s -> Printf.sprintf "%s = %s" name (quoted s)

(** The info string a canonical header writes. string -> [(string, value)] -> string *)
let canonical_info language attrs = String.concat " " (language :: List.map attribute_text attrs)

(** Whether two attribute lists say the same, whatever their order. *)
let same_attrs a b =
  List.length a = List.length b
  && List.for_all (fun (k, v) -> match List.assoc_opt k b with Some w -> v = w | None -> false) a

(* --- lines --- *)

let without_cr line =
  let n = String.length line in
  if n > 0 && line.[n - 1] = '\r' then String.sub line 0 (n - 1) else line

let leading_spaces line =
  let n = String.length line in
  let i = ref 0 in
  while !i < n && line.[!i] = ' ' do incr i done;
  !i

let blank line = String.for_all (fun c -> c = ' ' || c = '\t') (without_cr line)

(** A fence's opening line: its indentation, marker and the rest.
    string -> (int, string, string)? *)
let fence_open line =
  let line = without_cr line in
  let indent = leading_spaces line in
  let n = String.length line in
  if indent > 3 || indent >= n || (line.[indent] <> '`' && line.[indent] <> '~') then None
  else
    let c = line.[indent] in
    let j = ref indent in
    while !j < n && line.[!j] = c do incr j done;
    let marker = String.sub line indent (!j - indent) in
    let rest = String.sub line !j (n - !j) in
    if String.length marker < 3 || (c = '`' && String.contains rest '`') then None
    else Some (indent, marker, rest)

(** Whether line closes a fence opened with marker. string -> string -> bool *)
let closes marker line =
  let line = without_cr line in
  let indent = leading_spaces line in
  let n = String.length line in
  indent <= 3
  && indent < n
  && line.[indent] = marker.[0]
  &&
  let j = ref indent in
  while !j < n && line.[!j] = marker.[0] do incr j done;
  !j - indent >= String.length marker
  && String.for_all (fun c -> c = ' ' || c = '\t') (String.sub line !j (n - !j))

let html_tags =
  [ "address"; "article"; "aside"; "blockquote"; "body"; "caption"; "center"; "col"; "colgroup"; "dd";
    "details"; "dialog"; "dir"; "div"; "dl"; "dt"; "fieldset"; "figcaption"; "figure"; "footer"; "form";
    "h1"; "h2"; "h3"; "h4"; "h5"; "h6"; "head"; "header"; "hr"; "html"; "iframe"; "legend"; "li"; "link";
    "main"; "menu"; "nav"; "ol"; "optgroup"; "option"; "p"; "picture"; "pre"; "section"; "script";
    "source"; "style"; "summary"; "table"; "tbody"; "td"; "template"; "tfoot"; "th"; "thead"; "title";
    "tr"; "track"; "ul"; "video"; "audio" ]

(** Whether a line starts an HTML block, and whether it is a comment.
    string -> (bool, bool) *)
let html_start line =
  let line = without_cr line in
  let indent = leading_spaces line in
  if indent > 3 then (false, false)
  else
    let rest = String.sub line indent (String.length line - indent) in
    if String.starts_with ~prefix:"<!--" rest then (true, true)
    else if String.length rest < 2 || rest.[0] <> '<' then (false, false)
    else
      let i = if rest.[1] = '/' then 2 else 1 in
      let n = String.length rest in
      let j = ref i in
      while !j < n && (match rest.[!j] with 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true | _ -> false) do incr j done;
      let tag = String.lowercase_ascii (String.sub rest i (!j - i)) in
      let ends = !j = n || is_space rest.[!j] || rest.[!j] = '/' || rest.[!j] = '>' in
      (List.mem tag html_tags && ends, false)

let math_open line =
  let line = without_cr line in
  let indent = leading_spaces line in
  indent <= 3 && String.length line >= indent + 2 && String.sub line indent 2 = "$$"

let front_matter_line line = let t = without_cr line in
  let trailing s = String.for_all (fun c -> c = ' ' || c = '\t') s in
  (String.starts_with ~prefix:"---" t && trailing (String.sub t 3 (String.length t - 3)))

(** The text's lines, each with its newline where it has one. string -> [string] *)
let lines_of text =
  let n = String.length text in
  let rec go start acc =
    if start >= n then List.rev acc
    else
      match String.index_from_opt text start '\n' with
      | Some j -> go (j + 1) (String.sub text start (j + 1 - start) :: acc)
      | None -> List.rev (String.sub text start (n - start) :: acc)
  in
  go 0 []

let chomp line =
  let n = String.length line in
  if n > 0 && line.[n - 1] = '\n' then String.sub line 0 (n - 1) else line

(** The text split into the text between notebook blocks and the
    blocks: a fence at the left margin in one of the notebook's
    languages, found where markdown.js finds a fenced block -- not
    inside another fenced block, an HTML block, display math or the
    front matter. string -> [piece] *)
let scan text =
  let lines = Array.of_list (lines_of text) in
  let count = Array.length lines in
  let pieces = ref [] in
  let buffer = Buffer.create 256 in
  let flush () =
    if Buffer.length buffer > 0 then (
      pieces := Text (Buffer.contents buffer) :: !pieces;
      Buffer.clear buffer)
  in
  let text_line i = Buffer.add_string buffer lines.(i) in
  (* The front matter: a --- line, at least one more, and a --- or ... line. *)
  let start =
    if count > 2 && front_matter_line (chomp lines.(0)) && String.ends_with ~suffix:"\n" lines.(0) then
      let rec find k =
        if k >= count then 0
        else
          let t = without_cr (chomp lines.(k)) in
          let closing =
            (String.starts_with ~prefix:"---" t || String.starts_with ~prefix:"..." t)
            && String.for_all (fun c -> c = ' ' || c = '\t') (String.sub t 3 (String.length t - 3))
          in
          if closing then k + 1 else find (k + 1)
      in
      find 2
    else 0
  in
  for k = 0 to start - 1 do text_line k done;
  let rec normal i =
    if i < count then
      let line = chomp lines.(i) in
      match fence_open line with
      | Some (indent, marker, _) ->
          let rest = String.sub line (indent + String.length marker) (String.length line - indent - String.length marker) in
          let language, _ = parse_info rest in
          let rec body j = if j < count && not (closes marker (chomp lines.(j))) then body (j + 1) else j in
          let stop = body (i + 1) in
          if indent = 0 && List.mem language notebook_languages then (
            flush ();
            let inner = Buffer.create 256 in
            for k = i + 1 to stop - 1 do Buffer.add_string inner lines.(k) done;
            let close = if stop < count then Some (chomp lines.(stop)) else None in
            pieces :=
              Fence
                {
                  language;
                  attrs = typed_attrs (snd (parse_info rest));
                  info = rest;
                  marker;
                  body = Buffer.contents inner;
                  close;
                  gap = None;
                }
              :: !pieces;
            normal (stop + 1))
          else (
            for k = i to min stop (count - 1) do text_line k done;
            normal (stop + 1))
      | None ->
          let html, comment = html_start line in
          if math_open line then (
            let t = String.trim (without_cr line) in
            let first = String.sub t 2 (String.length t - 2) in
            text_line i;
            if String.length first >= 2 && String.ends_with ~suffix:"$$" first then normal (i + 1)
            else
              let rec until j =
                if j >= count then j
                else (
                  text_line j;
                  if String.ends_with ~suffix:"$$" (String.trim (without_cr (chomp lines.(j)))) then j + 1
                  else until (j + 1))
              in
              normal (until (i + 1)))
          else if html then
            if comment then
              let rec until j =
                if j >= count then j
                else (
                  text_line j;
                  let l = chomp lines.(j) in
                  let rec has k = k + 3 <= String.length l && (String.sub l k 3 = "-->" || has (k + 1)) in
                  if has 0 then j + 1 else until (j + 1))
              in
              normal (until i)
            else
              let rec until j = if j < count && not (blank (chomp lines.(j))) then (text_line j; until (j + 1)) else j in
              normal (until i)
          else (
            text_line i;
            normal (i + 1))
  in
  normal start;
  flush ();
  (* Blank text between two blocks is the second one's gap. *)
  let rec gaps pieces =
    match pieces with
    | Fence a :: Text t :: Fence b :: rest when String.for_all is_space t ->
        Fence a :: gaps (Fence { b with gap = Some t } :: rest)
    | Fence a :: Fence b :: rest -> Fence a :: gaps (Fence { b with gap = Some "" } :: rest)
    | p :: rest -> p :: gaps rest
    | [] -> []
  in
  gaps (List.rev !pieces)

(* --- the canonical layout --- *)

(** The marker a block's body can be fenced with: ``` unless a line of
    it would close that. string -> string *)
let canonical_marker body =
  let longest =
    List.fold_left
      (fun best line ->
        let line = without_cr (chomp line) in
        if closes "```" line then
          let i = leading_spaces line in
          let j = ref i in
          while !j < String.length line && line.[!j] = '`' do incr j done;
          max best (!j - i)
        else best)
      0 (lines_of body)
  in
  if longest = 0 then "```" else String.make (longest + 1) '`'

(** Lines of a block's body, without the newline after the last.
    string -> [string] *)
let body_lines body =
  let text = if String.ends_with ~suffix:"\n" body then String.sub body 0 (String.length body - 1) else body in
  String.split_on_char '\n' text

(** The marker a line starts with, after any blanks, and the rest after
    the blanks that follow it -- where a blank or the end of the line
    follows the marker. [string] -> string -> (string, string)? *)
let entry markers line =
  let n = String.length line in
  let i = ref 0 in
  while !i < n && is_space line.[!i] do incr i done;
  let rest = String.sub line !i (n - !i) in
  let found =
    List.find_map
      (fun m ->
        if m = "[]" then
          if String.length rest > 0 && rest.[0] = '[' then
            let j = ref 1 in
            while !j < String.length rest && is_space rest.[!j] do incr j done;
            if !j < String.length rest && rest.[!j] = ']' then Some ("[]", String.sub rest (!j + 1) (String.length rest - !j - 1))
            else None
          else None
        else if String.starts_with ~prefix:m rest then Some (m, String.sub rest (String.length m) (String.length rest - String.length m))
        else None)
      markers
  in
  match found with
  | None -> None
  | Some (m, after) ->
      if after = "" || String.for_all is_space after then Some (m, "")
      else if is_space after.[0] then
        let k = ref 0 in
        while !k < String.length after && is_space after.[!k] do incr k done;
        Some (m, String.sub after !k (String.length after - !k))
      else None

(** A quiz's question and alternatives, as markdown.js reads them.
    string -> (string, [(string, string)]) *)
let quiz_parts body =
  let question, items =
    List.fold_left
      (fun (question, items) line ->
        match entry [ "*"; "[]" ] line with
        | Some (m, text) -> (question, (m, [ text ]) :: items)
        | None -> (
            match items with
            | (m, lines) :: rest -> (question, (m, line :: lines) :: rest)
            | [] -> (line :: question, items)))
      ([], []) (body_lines body)
  in
  ( trim_spaces (String.concat "\n" (List.rev question)),
    List.rev_map (fun (m, lines) -> (m, trim_spaces (String.concat "\n" (List.rev lines)))) items )

(** An answer's entries, as markdown.js reads them: each right (->) or
    not, with its explanation. string -> [(bool, string)] *)
let answer_parts body =
  let items =
    List.fold_left
      (fun items line ->
        match entry [ "->"; "-" ] line with
        | Some (m, text) -> (m = "->", [ text ]) :: items
        | None -> (match items with (c, lines) :: rest -> (c, line :: lines) :: rest | [] -> items))
      [] (body_lines body)
  in
  List.rev_map (fun (c, lines) -> (c, trim_spaces (String.concat "\n" (List.rev lines)))) items

let with_rest marker text = if text = "" then marker else marker ^ " " ^ text

let quiz_body question alternatives =
  let parts = (if question = "" then [] else [ question ]) @ List.map (fun (m, t) -> with_rest m t) alternatives in
  if parts = [] then "" else String.concat "\n\n" parts ^ "\n"

let answer_body entries =
  if entries = [] then "" else String.concat "\n" (List.map (fun (c, t) -> with_rest (if c then "->" else "-") t) entries) ^ "\n"

(* --- Markdown to JSON --- *)

let json_value v = match v with VString s -> Json.String s | VNumber f -> Json.Number f | VBool b -> Json.Bool b

let json_attrs attrs = Json.Object (List.map (fun (k, v) -> (k, json_value v)) attrs)

let pyking f = f.language = "pyking" || f.language = "pyk"

(** The language a canonical header names: pyking for pyk too. *)
let canonical_language f = if pyking f then "pyking" else f.language

(** The fields every block's JSON has: its attributes (but `drop`), its
    body under `key`, and how its lines were written where that is not
    the canonical way. fence -> string -> [string] -> [(string, Json)] *)
let fence_fields f key drop =
  let attrs = List.filter (fun (k, _) -> not (List.mem k drop)) f.attrs in
  let canonical = canonical_info (canonical_language f) (List.map (fun w -> (w, VBool true)) drop @ attrs) in
  let marker = canonical_marker f.body in
  (if attrs = [] then [] else [ ("attributes", json_attrs attrs) ])
  @ (if key = "" then [] else [ (key, Json.String f.body) ])
  @ (if f.info = canonical then [] else [ ("info", Json.String f.info) ])
  @ (if f.marker = marker then [] else [ ("fence", Json.String f.marker) ])
  @ (match f.close with Some c when c = f.marker -> [] | Some c -> [ ("close", Json.String c) ] | None -> [ ("close", Json.Null) ])
  @ match f.gap with Some g when g <> "\n" -> [ ("gap", Json.String g) ] | _ -> []

let has_flag f name = List.assoc_opt name f.attrs = Some (VBool true)

(** A test under an exercise or a cell, as it is built: its blocks, by
    slot, in the order written. *)
type test = (string * fence) list

(** The JSON of a group's owner: an exercise or a cell, with what came
    under it. *)
type owner = {
  head : fence;
  is_exercise : bool;
  solution : fence option;
  tests : test list;  (** the last first *)
  allowed : fence list;  (** the last first *)
  order : string list;  (** the blocks after the head, the last first *)
}

let test_json (t : test) =
  let slots = [ "stdin"; "events"; "stdout"; "stderr" ] in
  Json.Object
    (List.filter_map
       (fun slot -> Option.map (fun f -> (slot, Json.Object (fence_fields f "text" []))) (List.assoc_opt slot t))
       slots)

let canonical_order o =
  let tests = List.rev o.tests in
  (match o.solution with Some _ -> [ "solution" ] | None -> [])
  @ List.concat
      (List.mapi
         (fun k t ->
           List.filter_map
             (fun slot -> if List.mem_assoc slot t then Some (Printf.sprintf "tests[%d].%s" k slot) else None)
             [ "stdin"; "events"; "stdout"; "stderr" ])
         tests)
  @ List.mapi (fun k _ -> Printf.sprintf "diff_allowed[%d]" k) (List.rev o.allowed)

let owner_json o =
  let drop = if o.is_exercise then [ "exercise" ] else [] in
  let tests = List.rev o.tests in
  let order = List.rev o.order in
  [ ("type", Json.String (if o.is_exercise then "exercise" else "cell")) ]
  @ fence_fields o.head "code" drop
  @ (match o.solution with Some s -> [ ("solution", Json.Object (fence_fields s "code" [ "solution" ])) ] | None -> [])
  @ (if tests = [] && not o.is_exercise then [] else [ ("tests", Json.List (List.map test_json tests)) ])
  @ (if o.allowed = [] then []
     else [ ("diff_allowed", Json.List (List.rev_map (fun f -> Json.Object (fence_fields f "text" [])) o.allowed)) ])
  @ if order = canonical_order o then [] else [ ("order", Json.List (List.map (fun s -> Json.String s) order)) ]

let block_json f =
  Json.Object
    ([ ("type", Json.String "block"); ("language", Json.String (canonical_language f)) ]
    @ fence_fields f (if pyking f then "code" else "text") [])

let quiz_json q answer =
  let question, alternatives = quiz_parts q.body in
  let raw = if quiz_body question alternatives = q.body then [] else [ ("body", Json.String q.body) ] in
  let answer_fields =
    match answer with
    | None -> []
    | Some a ->
        let entries = answer_parts a.body in
        let raw = if answer_body entries = a.body then [] else [ ("body", Json.String a.body) ] in
        [
          ( "answer",
            Json.Object
              ([
                 ( "entries",
                   Json.List
                     (List.map
                        (fun (c, t) -> Json.Object [ ("correct", Json.Bool c); ("text", Json.String t) ])
                        entries) );
               ]
              @ raw @ fence_fields a "" []) );
        ]
  in
  let fields = fence_fields q "" [] in
  Json.Object
    ([ ("type", Json.String "quiz") ]
    @ List.filter (fun (k, _) -> k = "attributes") fields
    @ [
        ("question", Json.String question);
        ( "alternatives",
          Json.List
            (List.map (fun (m, t) -> Json.Object [ ("marker", Json.String m); ("text", Json.String t) ]) alternatives) );
      ]
    @ raw
    @ List.filter (fun (k, _) -> k <> "attributes") fields
    @ answer_fields)

(** The JSON of one run of blocks with only blank lines between them,
    grouped as exercises.js groups them. [fence] -> [Json] *)
let group_json fences =
  let out = ref [] in
  let emit j = out := j :: !out in
  let owner = ref None in
  let end_owner () =
    (match !owner with Some o -> emit (Json.Object (owner_json o)) | None -> ());
    owner := None
  in
  let add o name = { o with order = name :: o.order } in
  let rec go fences =
    match fences with
    | [] -> end_owner ()
    | f :: rest -> (
        let next = match rest with g :: _ -> Some g | [] -> None in
        let attach kind =
          match !owner, kind with
          | Some o, "solution" when o.is_exercise && o.solution = None && o.tests = [] ->
              owner := Some (add { o with solution = Some f } "solution");
              true
          | Some o, "diff-allowed" when o.is_exercise ->
              owner := Some (add { o with allowed = f :: o.allowed } (Printf.sprintf "diff_allowed[%d]" (List.length o.allowed)));
              true
          | Some o, "stdin" when o.is_exercise || List.exists (fun g -> List.mem g.language [ "stdout"; "stderr"; "events" ]) (Option.to_list next) ->
              let k = List.length o.tests in
              owner := Some (add { o with tests = [ ("stdin", f) ] :: o.tests } (Printf.sprintf "tests[%d].stdin" k));
              true
          | Some o, "events" -> (
              match o.tests with
              | last :: older when not (List.exists (fun s -> List.mem_assoc s last) [ "events"; "stdout"; "stderr" ]) ->
                  let k = List.length older in
                  owner := Some (add { o with tests = (last @ [ ("events", f) ]) :: older } (Printf.sprintf "tests[%d].events" k));
                  true
              | _ ->
                  let k = List.length o.tests in
                  owner := Some (add { o with tests = [ ("events", f) ] :: o.tests } (Printf.sprintf "tests[%d].events" k));
                  true)
          | Some o, ("stdout" | "stderr" as slot) -> (
              match o.tests with
              | last :: older when not (List.mem_assoc slot last) ->
                  let k = List.length older in
                  owner := Some (add { o with tests = (last @ [ (slot, f) ]) :: older } (Printf.sprintf "tests[%d].%s" k slot));
                  true
              | _ ->
                  let k = List.length o.tests in
                  owner := Some (add { o with tests = [ (slot, f) ] :: o.tests } (Printf.sprintf "tests[%d].%s" k slot));
                  true)
          | _ -> false
        in
        let kind =
          if pyking f && has_flag f "exercise" then "exercise"
          else if pyking f && has_flag f "solution" then "solution"
          else if pyking f then "cell"
          else f.language
        in
        match kind with
        | "exercise" | "cell" ->
            end_owner ();
            owner := Some { head = f; is_exercise = kind = "exercise"; solution = None; tests = []; allowed = []; order = [] };
            go rest
        | "quiz" -> (
            end_owner ();
            match next with
            | Some a when a.language = "answer" ->
                emit (quiz_json f (Some a));
                go (List.tl rest)
            | _ ->
                emit (quiz_json f None);
                go rest)
        | "rules" ->
            end_owner ();
            emit (Json.Object ([ ("type", Json.String "rules") ] @ fence_fields f "text" []));
            go rest
        | "solution" | "stdin" | "events" | "stdout" | "stderr" | "diff-allowed" ->
            if not (attach kind) then (
              end_owner ();
              emit (block_json f));
            go rest
        | _ ->
            end_owner ();
            emit (block_json f);
            go rest)
  in
  go fences;
  List.rev !out

(** The notebook text holds, as JSON. string -> Json *)
let of_markdown text =
  let pieces = scan text in
  let rec blocks pieces =
    match pieces with
    | [] -> []
    | Text t :: rest -> Json.Object [ ("type", Json.String "markdown"); ("text", Json.String t) ] :: blocks rest
    | Fence _ :: _ ->
        let rec take pieces acc =
          match pieces with
          | Fence f :: rest when acc = [] || f.gap <> None -> take rest (f :: acc)
          | rest -> (List.rev acc, rest)
        in
        let group, rest = take pieces [] in
        group_json group @ blocks rest
  in
  let final_newline =
    text = "" || String.ends_with ~suffix:"\n" text
    || (match List.rev pieces with Fence { close = None; _ } :: _ | Text _ :: _ -> true | _ -> false)
  in
  Json.Object
    ([ ("format", Json.String "pyking-notebook"); ("version", Json.Number 1.); ("blocks", Json.List (blocks pieces)) ]
    @ if final_newline then [] else [ ("final_newline", Json.Bool false) ])

(* --- JSON to Markdown --- *)

let fail fmt = Printf.ksprintf (fun message -> raise (Format_error message)) fmt

let field where name value =
  match value with Json.Object fields -> List.assoc_opt name fields | _ -> fail "%s is not an object" where

let string_field where name value =
  match field where name value with
  | Some (Json.String s) -> Some s
  | None | Some Json.Null -> None
  | Some _ -> fail "%s.%s is not a string" where name

let required_string where name value =
  match string_field where name value with Some s -> s | None -> fail "%s has no %s" where name

let read_attrs where value =
  match field where "attributes" value with
  | None -> []
  | Some (Json.Object fields) ->
      List.map
        (fun (k, v) ->
          match v with
          | Json.String s -> (k, VString s)
          | Json.Number f -> (k, VNumber f)
          | Json.Bool b -> (k, VBool b)
          | _ -> fail "%s.attributes.%s is not a string, a number or a boolean" where k)
        fields
  | Some _ -> fail "%s.attributes is not an object" where

(** One block's lines, written from its JSON: the header written as the
    source wrote it where its `info` still says what `attributes` does,
    and in the canonical way where not. `languages` are those the block
    may be written in, the first canonical; `marker_word` a word written
    first, standing for what the block is. *)
let fence_text where value ~languages ~marker_word ~body =
  let attrs = read_attrs where value in
  let attrs = match marker_word with Some w -> (w, VBool true) :: attrs | None -> attrs in
  let canonical = canonical_info (List.hd languages) attrs in
  let info =
    match string_field where "info" value with
    | Some raw ->
        let language, parsed = parse_info raw in
        if List.mem language languages && same_attrs (typed_attrs parsed) attrs then raw else canonical
    | None -> canonical
  in
  let marker =
    match string_field where "fence" value with
    | Some m
      when String.length m >= 3
           && String.for_all (fun c -> c = m.[0]) m
           && (m.[0] = '`' || m.[0] = '~')
           && not (List.exists (closes m) (List.map chomp (lines_of body))) ->
        m
    | _ -> canonical_marker body
  in
  let close =
    match field where "close" value with
    | Some Json.Null -> None
    | Some (Json.String c) when closes marker c -> Some c
    | _ -> Some marker
  in
  let gap =
    match string_field where "gap" value with Some g when String.for_all is_space g -> g | _ -> "\n"
  in
  (gap, marker ^ info ^ "\n", body, close)

(** The Markdown a notebook's JSON stands for. Raises Format_error where
    the value is not a notebook. Json -> string *)
let to_markdown value =
  (match field "the notebook" "format" value with
  | Some (Json.String "pyking-notebook") -> ()
  | _ -> fail "the notebook has no \"format\": \"pyking-notebook\"");
  let blocks = match field "the notebook" "blocks" value with Some (Json.List b) -> b | _ -> fail "the notebook has no blocks list" in
  let out = Buffer.create 4096 in
  let after_fence = ref false in
  let put (gap, opening, body, close) =
    if !after_fence then Buffer.add_string out gap
    else if Buffer.length out > 0 && Buffer.nth out (Buffer.length out - 1) <> '\n' then Buffer.add_char out '\n';
    Buffer.add_string out opening;
    Buffer.add_string out body;
    (match close with
    | Some c ->
        if body <> "" && not (String.ends_with ~suffix:"\n" body) then Buffer.add_char out '\n';
        Buffer.add_string out (c ^ "\n")
    | None -> ());
    after_fence := true
  in
  let io where value languages = fence_text where value ~languages ~marker_word:None ~body:(required_string where "text" value) in
  let pyking_block where value word =
    fence_text where value ~languages:[ "pyking"; "pyk" ] ~marker_word:word ~body:(required_string where "code" value)
  in
  let tests_of where value =
    match field where "tests" value with
    | None -> []
    | Some (Json.List tests) ->
        List.mapi
          (fun k t ->
            let where = Printf.sprintf "%s.tests[%d]" where k in
            match t with
            | Json.Object fields ->
                List.map
                  (fun (slot, v) ->
                    if not (List.mem slot [ "stdin"; "events"; "stdout"; "stderr" ]) then fail "%s has a %s" where slot;
                    (slot, io (where ^ "." ^ slot) v [ slot ]))
                  fields
            | _ -> fail "%s is not an object" where)
          tests
    | Some _ -> fail "%s.tests is not a list" where
  in
  let owner where value word =
    put (pyking_block where value word);
    let solution =
      match field where "solution" value with
      | None | Some Json.Null -> []
      | Some s -> [ ("solution", pyking_block (where ^ ".solution") s (Some "solution")) ]
    in
    let tests = tests_of where value in
    let allowed =
      match field where "diff_allowed" value with
      | None -> []
      | Some (Json.List items) -> List.mapi (fun k v -> io (Printf.sprintf "%s.diff_allowed[%d]" where k) v [ "diff-allowed" ]) items
      | Some _ -> fail "%s.diff_allowed is not a list" where
    in
    let named =
      solution
      @ List.concat
          (List.mapi
             (fun k slots ->
               let ordered = List.filter_map (fun s -> Option.map (fun t -> (s, t)) (List.assoc_opt s slots)) [ "stdin"; "events"; "stdout"; "stderr" ] in
               List.map (fun (s, t) -> (Printf.sprintf "tests[%d].%s" k s, t)) ordered)
             tests)
      @ List.mapi (fun k t -> (Printf.sprintf "diff_allowed[%d]" k, t)) allowed
    in
    let order =
      match field where "order" value with
      | Some (Json.List names) ->
          let names = List.map (function Json.String s -> s | _ -> fail "%s.order holds a value that is not a string" where) names in
          if List.sort compare names = List.sort compare (List.map fst named) then names else List.map fst named
      | _ -> List.map fst named
    in
    List.iter (fun name -> put (List.assoc name named)) order
  in
  List.iteri
    (fun k block ->
      let where = Printf.sprintf "blocks[%d]" k in
      match string_field where "type" block with
      | Some "markdown" ->
          Buffer.add_string out (required_string where "text" block);
          after_fence := false
      | Some "rules" -> put (io where block [ "rules" ])
      | Some "cell" -> owner where block None
      | Some "exercise" -> owner where block (Some "exercise")
      | Some "quiz" ->
          let question = Option.value ~default:"" (string_field where "question" block) in
          let alternatives =
            match field where "alternatives" block with
            | Some (Json.List items) ->
                List.mapi
                  (fun j item ->
                    let w = Printf.sprintf "%s.alternatives[%d]" where j in
                    let m = required_string w "marker" item in
                    if m <> "*" && m <> "[]" then fail "%s.marker is * or []" w;
                    (m, required_string w "text" item))
                  items
            | None -> []
            | Some _ -> fail "%s.alternatives is not a list" where
          in
          let body =
            match string_field where "body" block with
            | Some raw when quiz_parts raw = (question, alternatives) -> raw
            | _ -> quiz_body question alternatives
          in
          put (fence_text where block ~languages:[ "quiz" ] ~marker_word:None ~body);
          (match field where "answer" block with
          | None | Some Json.Null -> ()
          | Some answer ->
              let w = where ^ ".answer" in
              let entries =
                match field w "entries" answer with
                | Some (Json.List items) ->
                    List.mapi
                      (fun j item ->
                        let w = Printf.sprintf "%s.entries[%d]" w j in
                        let correct = match field w "correct" item with Some (Json.Bool b) -> b | _ -> fail "%s.correct is not true or false" w in
                        (correct, required_string w "text" item))
                      items
                | _ -> fail "%s has no entries list" w
              in
              let body =
                match string_field w "body" answer with
                | Some raw when answer_parts raw = entries -> raw
                | _ -> answer_body entries
              in
              put (fence_text w answer ~languages:[ "answer" ] ~marker_word:None ~body))
      | Some "block" ->
          let language = required_string where "language" block in
          let family = language = "pyking" || language = "pyk" in
          let key = if family then "code" else "text" in
          put
            (fence_text where block
               ~languages:(if family then [ "pyking"; "pyk" ] else [ language ])
               ~marker_word:None ~body:(required_string where key block))
      | Some other -> fail "%s has the type '%s', which no block has" where other
      | None -> fail "%s has no type" where)
    blocks;
  let text = Buffer.contents out in
  match field "the notebook" "final_newline" value with
  | Some (Json.Bool false) when String.ends_with ~suffix:"\n" text -> String.sub text 0 (String.length text - 1)
  | _ -> text

(* --- the schema --- *)

let obj fields = Json.Object fields
let str s = Json.String s
let typ t = ("type", str t)
let refer name = obj [ ("$ref", str ("#/$defs/" ^ name)) ]
let text_of description = obj [ typ "string"; ("description", str description) ]

let raw_fields =
  [
    ("info", text_of "The header after the fence marker, as written, where it is not the canonical `language key = value ...`. Used when it still says what `attributes` does.");
    ("fence", obj [ typ "string"; ("pattern", str "^(`{3,}|~{3,})$"); ("description", str "The opening fence marker, where it is not ```.") ]);
    ("close", obj [ ("type", Json.List [ str "string"; str "null" ]); ("description", str "The closing fence line, where it is not the opening marker; null where the block runs to the end of the document.") ]);
    ("gap", obj [ typ "string"; ("pattern", str "^[ \\t\\r\\n]*$"); ("description", str "The blank lines between this block and the block right before it, where they are not one empty line.") ]);
  ]

let attributes props =
  ( "attributes",
    obj [ typ "object"; ("additionalProperties", Json.Bool false); ("properties", obj props) ] )

let kind_def ?(required = []) ?(extra = []) kind description props =
  obj
    [
      typ "object";
      ("description", str description);
      ("additionalProperties", Json.Bool false);
      ("required", Json.List (List.map str ([ "type" ] @ required)));
      ("properties", obj ([ ("type", obj [ ("const", str kind) ]) ] @ props @ raw_fields @ extra));
    ]

let sub_def ?(required = []) description props =
  obj
    [
      typ "object";
      ("description", str description);
      ("additionalProperties", Json.Bool false);
      ("required", Json.List (List.map str required));
      ("properties", obj (props @ raw_fields));
    ]

let boolean d = obj [ typ "boolean"; ("description", str d) ]
let number d = obj [ typ "number"; ("minimum", Json.Number 0.); ("description", str d) ]
let count d = obj [ typ "integer"; ("minimum", Json.Number 1.); ("description", str d) ]

let name_attr =
  ( "name",
    obj
      [ typ "string"; ("pattern", str "^[A-Za-z0-9][A-Za-z0-9_-]*$");
        ("description", str "What the item is called, unique in the notebook.") ] )

let order_prop =
  ( "order",
    obj
      [
        typ "array";
        ("description", str "The blocks after the head in the order written, where it is not solution, then each test's stdin, events, stdout and stderr, then the diff-allowed blocks.");
        ("items", obj [ typ "string"; ("pattern", str "^(solution|tests\\[[0-9]+\\]\\.(stdin|events|stdout|stderr)|diff_allowed\\[[0-9]+\\])$") ]);
      ] )

let tests_prop = ("tests", obj [ typ "array"; ("items", refer "test") ])

(** The JSON Schema every notebook's JSON follows, as text. string *)
let schema =
  Json.pretty
    (obj
       [
         ("$schema", str "https://json-schema.org/draft/2020-12/schema");
         ("$id", str "https://pyking.org/notebook.schema.json");
         ("title", str "Pyking notebook");
         ("description", str "A Pyking notebook as JSON, as `pyk notebook --to-json` writes it: the Markdown between its blocks kept as written, and each exercise, quiz, cell and other notebook block structured. `pyk notebook --to-markdown` writes it back as the same Markdown. See docs/notebook.md.");
         typ "object";
         ("additionalProperties", Json.Bool false);
         ("required", Json.List [ str "format"; str "version"; str "blocks" ]);
         ( "properties",
           obj
             [
               ("format", obj [ ("const", str "pyking-notebook") ]);
               ("version", obj [ ("const", Json.Number 1.) ]);
               ("final_newline", obj [ typ "boolean"; ("description", str "false where the document does not end with a newline.") ]);
               ("blocks", obj [ typ "array"; ("items", refer "block") ]);
             ] );
         ( "$defs",
           obj
             [
               ( "block",
                 obj
                   [
                     ( "oneOf",
                       Json.List
                         (List.map refer [ "markdown"; "rules"; "cell"; "exercise"; "quiz"; "other" ]) );
                   ] );
               ( "markdown",
                 obj
                   [
                     typ "object"; ("description", str "Markdown between notebook blocks, exactly as written.");
                     ("additionalProperties", Json.Bool false);
                     ("required", Json.List [ str "type"; str "text" ]);
                     ("properties", obj [ ("type", obj [ ("const", str "markdown") ]); ("text", obj [ typ "string" ]) ]);
                   ] );
               ( "rules",
                 kind_def "rules" "A ```rules block: what the student is told, with the points." ~required:[ "text" ]
                   [ attributes [ ("max", number "The points every graded item gives together."); ("pass", number "The points that pass.") ];
                     ("text", text_of "Its Markdown, each line with its newline.") ] );
               ( "cell",
                 kind_def "cell" "A ```pyking cell, with the stdin, events, stdout and stderr blocks under it." ~required:[ "code" ]
                   [ attributes
                       [ ("norun", boolean "Highlighted only."); ("readonly", boolean "Runnable, not editable.");
                         ("error", boolean "Meant to be refused."); ("playground", boolean "The website's link to the playground.");
                         ("stdin", text_of "What it reads on standard input."); ("args", text_of "Its arguments, as one line.") ];
                     ("code", text_of "The program, each line with its newline.");
                     tests_prop; order_prop ] );
               ( "exercise",
                 kind_def "exercise" "A ```pyking exercise block, the starting code, with its solution, tests and diff-allowed blocks." ~required:[ "code" ]
                   [ attributes
                       [ name_attr; ("attempts", count "How many times Submit may fail."); ("points", number "What solving it gives.");
                         ("penalty", number "Taken off for each failed Submit.");
                         ("stdin", text_of "The input a test without its own reads."); ("args", text_of "The arguments a test without its own is given.");
                         ("readonly", boolean "The starting code cannot be edited.");
                         ("method", obj [ ("enum", Json.List [ str "inline"; str "git" ]); ("description", str "Answered in the page, or pushed with git and graded elsewhere.") ]) ];
                     ("code", text_of "The starting code.");
                     ("solution", refer "solution"); tests_prop;
                     ("diff_allowed", obj [ typ "array"; ("items", refer "diff_allowed") ]); order_prop ] );
               ( "solution",
                 sub_def "A ```pyking solution block." ~required:[ "code" ]
                   [ attributes
                       [ ("available", boolean "A student may ask to see it."); ("readonly", boolean "Cannot be edited.");
                         ("stdin", text_of "What it reads when it runs on its own."); ("args", text_of "Its arguments when it runs on its own.");
                         ("save_canvas", text_of "The tinyweb canvas saved as a picture."); ("file", text_of "The .png it is saved as.") ];
                     ("code", text_of "The solution.") ] );
               ( "test",
                 obj
                   [ typ "object"; ("description", str "One test: its input, the events it is sent, and what it should write.");
                     ("additionalProperties", Json.Bool false); ("minProperties", Json.Number 1.);
                     ( "properties",
                       obj [ ("stdin", refer "stdin"); ("events", refer "events"); ("stdout", refer "output"); ("stderr", refer "output") ] ) ] );
               ( "stdin",
                 sub_def "A ```stdin block: what a test reads." ~required:[ "text" ]
                   [ attributes
                       [ ("args", text_of "The test's arguments."); ("visible", boolean "A student is shown it.");
                         ("lines_per_multi_input", count "A test for every this many lines.") ];
                     ("text", text_of "What is read, each line with its newline.") ] );
               ( "events",
                 sub_def "An ```events block: the tinyweb events a test is sent once its top level has ended." ~required:[ "text" ]
                   [ attributes [ ("visible", boolean "A student is shown it.") ]; ("text", text_of "One event a line, as an events file writes it.") ] );
               ( "output",
                 sub_def "A ```stdout or ```stderr block: what a test should write." ~required:[ "text" ]
                   [ attributes [ ("visible", boolean "A student is shown it.") ]; ("text", text_of "What is written, each line with its newline.") ] );
               ( "diff_allowed",
                 sub_def "A ```diff-allowed block: lines whose numbers may differ by [+/-N]." ~required:[ "text" ]
                   [ attributes []; ("text", text_of "One pattern a line.") ] );
               ( "quiz",
                 kind_def "quiz" "A ```quiz block and its ```answer." ~required:[ "alternatives" ]
                   [ attributes
                       [ name_attr; ("attempts", count "How many times Submit may fail."); ("points", number "What answering it right gives.");
                         ("penalty", number "Taken off for each failed Submit.");
                         ("available", boolean "The answers are shown once the attempts are used up.");
                         ("one_point_correct", boolean "One point for each right alternative checked.") ];
                     ("question", text_of "The question inside the block, before the first alternative.");
                     ( "alternatives",
                       obj
                         [ typ "array";
                           ( "items",
                             obj
                               [ typ "object"; ("additionalProperties", Json.Bool false);
                                 ("required", Json.List [ str "marker"; str "text" ]);
                                 ( "properties",
                                   obj [ ("marker", obj [ ("enum", Json.List [ str "*"; str "[]" ]); ("description", str "* where one is chosen, [] where any number are.") ]);
                                         ("text", obj [ typ "string" ]) ] ) ] ) ] );
                     ("body", text_of "The block's text, where it is not written the canonical way.");
                     ("answer", refer "answer") ] );
               ( "answer",
                 sub_def "An ```answer block: an entry for each alternative, in order." ~required:[ "entries" ]
                   [ ( "entries",
                       obj
                         [ typ "array";
                           ( "items",
                             obj
                               [ typ "object"; ("additionalProperties", Json.Bool false);
                                 ("required", Json.List [ str "correct"; str "text" ]);
                                 ("properties", obj [ ("correct", boolean "-> where right, - where wrong."); ("text", text_of "What explains it.") ]) ] ) ] );
                     ("body", text_of "The block's text, where it is not written the canonical way.") ] );
               ( "other",
                 kind_def "block" "Any other notebook block where it stands: one that belongs to no exercise, cell or quiz there." ~required:[ "language" ]
                   [ ("language", obj [ ("enum", Json.List (List.map str notebook_languages)) ]);
                     ( "attributes",
                       obj [ typ "object"; ("additionalProperties", obj [ ("type", Json.List [ str "string"; str "number"; str "boolean" ]) ]) ] );
                     ("text", obj [ typ "string" ]); ("code", obj [ typ "string" ]) ] );
             ] );
       ])
