(** The Pyking language server: a state and one function from a message an
    editor sent to the messages to send back. It checks a document with
    the compiler's own front end -- Module.load, Typesystem.type_check,
    Analyses.analyze_mutability -- and reads hover, definition, outline
    and completion out of what that produced. No file is opened here:
    the caller hands in where files come from, so the same server runs
    in `pyk lsp` and in the browser. See design/lsp.md.

    Data structures:
      settings -- what the editor configured.
      document -- one open file.
      analysis -- what checking one document as a program found.
      phase -- where the protocol is.
      state -- everything the server knows.

    Functions:
      create sources libs version -- a server that has seen nothing.
      handle state text -- one message received, and what to send back.
      idle state -- the diagnostics of every document due to be checked.
      exit_code state -- the status to exit with, once `exit` arrived. *)

open Syntax
open Scopes

(* What the editor configured: more library directories, whether to
   check only on save, and whether to show the types it inferred in the
   text. *)
type settings = { lib_path : string list; on_save : bool; inlay_hints : bool }

(* One open file: its URI and path, its text and version as the editor
   last sent them, and whether it is due to be checked. *)
type document = { uri : string; path : string; text : string; version : int; due : bool }

(* The first error a check found: where, pyk's label for its stage, and
   what it says. *)
type problem = { at : Lexer.info; kind : string; message : string }

(* What checking a document as a program found: the version checked,
   the modules loaded, each checked module's types and exports, the last
   check that reached the document's own module, and the error or the
   internal failure that stopped it. *)
type analysis = {
  checked_version : int;
  units : Module.t list;
  tmaps : (string * typ IntMap.t) list;
  sigmaps : (string * Typesystem.sigmap) list;
  typed : (Module.t list * (string * typ IntMap.t) list) option;
  problem : problem option;
  internal : string option;
}

(* Where the protocol is: before initialize, running, after shutdown, and
   after exit with the status to end with. *)
type phase = Fresh | Running | Shut_down | Exited of int

(* Everything the server knows: where files come from, the library path,
   its version, the settings, the open documents, each one's analysis,
   what was last published for each, and the phase. *)
type state = {
  base : Module.sources;
  libs : Module.lib_entry list;
  server_version : string;
  settings : settings;
  documents : document list;
  analyses : (string * analysis) list;
  published : (string * string) list;
  phase : phase;
}

let create base libs server_version =
  {
    base;
    libs;
    server_version;
    settings = { lib_path = []; on_save = false; inlay_hints = true };
    documents = [];
    analyses = [];
    published = [];
    phase = Fresh;
  }

let exit_code state = match state.phase with Exited code -> Some code | _ -> None

(* --- paths and URIs --- *)

(** A URI's path with its %XX escapes decoded: file:///a/b%20c.pyk is
    /a/b c.pyk, and file:///C:/x.pyk is C:/x.pyk. string -> string *)
let path_of_uri uri =
  let rest =
    if String.length uri >= 7 && String.sub uri 0 7 = "file://" then
      String.sub uri 7 (String.length uri - 7)
    else uri
  in
  let rest =
    if String.length rest >= 9 && String.sub rest 0 9 = "localhost" then
      String.sub rest 9 (String.length rest - 9)
    else rest
  in
  let decoded = Buffer.create (String.length rest) in
  let n = String.length rest in
  let rec go i =
    if i < n then
      if rest.[i] = '%' && i + 2 < n then (
        match int_of_string_opt ("0x" ^ String.sub rest (i + 1) 2) with
        | Some c ->
            Buffer.add_char decoded (Char.chr c);
            go (i + 3)
        | None ->
            Buffer.add_char decoded '%';
            go (i + 1))
      else (
        Buffer.add_char decoded rest.[i];
        go (i + 1))
  in
  go 0;
  let path = Buffer.contents decoded in
  (* A Windows drive: /C:/x is C:/x. *)
  if String.length path >= 3 && path.[0] = '/' && path.[2] = ':' then
    String.sub path 1 (String.length path - 1)
  else path

(** The file URI of a path. string -> string *)
let uri_of_path path =
  let buffer = Buffer.create (String.length path + 8) in
  String.iter
    (fun c ->
      match c with
      | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' | '~' | '/' | ':' ->
          Buffer.add_char buffer c
      | '\\' -> Buffer.add_char buffer '/'
      | c -> Buffer.add_string buffer (Printf.sprintf "%%%02X" (Char.code c)))
    path;
  let encoded = Buffer.contents buffer in
  if String.length encoded > 0 && encoded.[0] = '/' then "file://" ^ encoded
  else "file:///" ^ encoded

(* --- positions --- *)

(** The lines of a text, without their line ends. string -> [string] *)
let lines_of text =
  List.map
    (fun line ->
      let n = String.length line in
      if n > 0 && line.[n - 1] = '\r' then String.sub line 0 (n - 1) else line)
    (String.split_on_char '\n' text)

(** Line `row` (counted from 1) of a text, or "" past its end.
    string -> int -> string *)
let line_at text row =
  match List.nth_opt (lines_of text) (row - 1) with Some line -> line | None -> ""

(** The length in bytes of the UTF-8 sequence a byte starts. char -> int *)
let utf8_length c =
  let b = Char.code c in
  if b < 0x80 then 1 else if b < 0xC0 then 1 else if b < 0xE0 then 2 else if b < 0xF0 then 3 else 4

(** How many UTF-16 code units the first `bytes` bytes of a line are.
    string -> int -> int *)
let utf16_of_bytes line bytes =
  let stop = min bytes (String.length line) in
  let rec go i units =
    if i >= stop then units + max 0 (bytes - String.length line)
    else
      let k = utf8_length line.[i] in
      go (i + k) (units + if k = 4 then 2 else 1)
  in
  go 0 0

(** How many bytes the first `units` UTF-16 code units of a line are.
    string -> int -> int *)
let bytes_of_utf16 line units =
  let n = String.length line in
  let rec go i u =
    if u >= units || i >= n then i
    else
      let k = utf8_length line.[i] in
      go (i + k) (u + if k = 4 then 2 else 1)
  in
  go 0 0

(** An LSP position for a row (from 1) and byte column of a text.
    string -> int -> int -> Json.t *)
let position text row col =
  Json.Object
    [
      ("line", Json.Number (float_of_int (max 0 (row - 1))));
      ("character", Json.Number (float_of_int (utf16_of_bytes (line_at text row) col)));
    ]

(** An LSP range for a span of a text. string -> Lexer.info -> Json.t *)
let range text (i : Lexer.info) =
  let row2, col2 = if (i.row2, i.col2) < (i.row1, i.col1) then (i.row1, i.col1) else (i.row2, i.col2) in
  Json.Object [ ("start", position text i.row1 i.col1); ("end", position text row2 col2) ]

(** The row (from 1) and byte column an LSP position names in a text.
    string -> Json.t -> (int, int) *)
let row_col text pos =
  let line = Option.value ~default:0 (Json.to_int_option (Json.member "line" pos)) in
  let character = Option.value ~default:0 (Json.to_int_option (Json.member "character" pos)) in
  (line + 1, bytes_of_utf16 (line_at text (line + 1)) character)

(** The byte offset of a row and column in a text. string -> int -> int -> int *)
let offset_of text row col =
  let lines = String.split_on_char '\n' text in
  let rec go lines r offset =
    match lines with
    | [] -> String.length text
    | line :: rest ->
        if r = row then min (offset + col) (offset + String.length line)
        else go rest (r + 1) (offset + String.length line + 1)
  in
  min (String.length text) (go lines 1 0)

(** Whether a span holds a row and byte column. Lexer.info -> int -> int -> bool *)
let contains (i : Lexer.info) row col =
  compare (i.row1, i.col1) (row, col) <= 0 && compare (row, col) (i.row2, i.col2) <= 0

(** How big a span is, for picking the smallest. Lexer.info -> (int, int) *)
let size (i : Lexer.info) = (i.row2 - i.row1, if i.row1 = i.row2 then i.col2 - i.col1 else i.col2)

(* --- files --- *)

(** Where a server's files come from: the open documents, then the
    caller's. state -> Module.sources *)
let sources state : Module.sources =
  let open_at path = List.find_opt (fun d -> d.path = path) state.documents in
  {
    exists = (fun path -> open_at path <> None || state.base.exists path);
    contents =
      (fun path ->
        match open_at path with Some d -> d.text | None -> state.base.contents path);
  }

(** A file's text, or "" where it cannot be read. state -> string -> string *)
let text_of state path =
  let s = sources state in
  try if s.exists path then s.contents path else "" with _ -> ""

(* --- checking a document --- *)

(** The label pyk gives an error of each stage, and its span and message.
    exn -> (Lexer.info, string, string)? *)
let describe error =
  match error with
  | Lexer.Lex_error (at, message) -> Some (at, "Lexing error", message)
  | Parser.Parse_error (at, message) -> Some (at, "Parsing error", message)
  | Module.Module_error (at, message) -> Some (at, "Module error", message)
  | Analyses.Analysis_error (at, message) -> Some (at, "Name error", message)
  | Typesystem.Type_error (at, message) -> Some (at, "Type error", message)
  | _ -> None

(** Checks one document as a program, as pyk does: every module it
    reaches, each against what the ones it imports export. Keeps the
    previous analysis's modules where this one could not load any.
    state -> document -> analysis? -> analysis *)
let analyse state document previous =
  let libs =
    state.libs
    @ List.map
        (fun directory -> Module.{ lib_directory = directory; lib_origin = "editor setting" })
        state.settings.lib_path
  in
  let kept =
    match previous with
    | Some a -> a
    | None -> { checked_version = -1; units = []; tmaps = []; sigmaps = []; typed = None; problem = None; internal = None }
  in
  (* Where this check did not reach the document's own module, its types
     come from the last check that did: stale, but each node there still
     has its own type. *)
  let typed units tmaps =
    if List.mem_assoc document.path tmaps then Some (units, tmaps)
    else match kept.typed with Some t -> Some t | None -> Some (units, tmaps)
  in
  let failed error units tmaps sigmaps =
    let base = { checked_version = document.version; units; tmaps; sigmaps; typed = typed units tmaps; problem = None; internal = None } in
    match describe error with
    | Some (at, kind, message) -> { base with problem = Some { at; kind; message } }
    | None -> { base with internal = Some (Printexc.to_string error) }
  in
  match Module.load ~from:(sources state) ~libs ~splash:false document.path with
  | exception error -> failed error kept.units kept.tmaps kept.sigmaps
  | units ->
      let rec check units_left tmaps sigmaps =
        match units_left with
        | [] ->
            { checked_version = document.version; units; tmaps; sigmaps; typed = Some (units, tmaps);
              problem = None; internal = None }
        | (unit : Module.t) :: rest ->
            if unit.is_external then
              check rest tmaps (sigmaps @ [ (unit.name, Module.external_sigmap unit.declarations) ])
            else (
              match
                let declared = Module.external_signatures unit.declarations in
                let tmap, _ =
                  Typesystem.type_check ~declared unit.stmts (Module.sigmaps_for unit sigmaps)
                in
                Analyses.analyze_mutability unit.stmts;
                (tmap, Module.module_sigmap unit.name unit.stmts unit.declarations tmap)
              with
              | exception error -> failed error units tmaps sigmaps
              | tmap, sigmap ->
                  check rest (tmaps @ [ (unit.path, tmap) ]) (sigmaps @ [ (unit.name, sigmap) ]))
      in
      check units [] []

(** The analysis of a document as it is now, checking it if it changed.
    state -> document -> (state, analysis) *)
let analysis_of state document =
  let previous = List.assoc_opt document.uri state.analyses in
  match previous with
  | Some a when a.checked_version = document.version -> (state, a)
  | _ ->
      let a = analyse state document previous in
      ({ state with analyses = (document.uri, a) :: List.remove_assoc document.uri state.analyses }, a)

(* --- answers --- *)

(** A doc comment's lines with each section line outside a code block --
    `# Parameters`, `# Returns`, `# Examples` -- made a bold label, which
    an editor's hover shows at the size of the text around it.
    [string] -> [string] *)
let section_labels lines =
  let _, out =
    List.fold_left
      (fun (fenced, out) line ->
        let fence = String.length line >= 3 && String.sub line 0 3 = "```" in
        let heading =
          (not fenced) && String.length line > 2 && String.sub line 0 2 = "# "
        in
        let shown =
          if heading then "**" ^ String.sub line 2 (String.length line - 2) ^ "**"
          else line
        in
        ((if fence then not fenced else fenced), shown :: out))
      (false, []) lines
  in
  List.rev out

(** The `##` comment written directly above a row of a file, without its
    markers. state -> string -> int -> string? *)
let doc_comment state file row =
  let lines = Array.of_list (lines_of (text_of state file)) in
  let rec go r acc =
    if r < 1 || r > Array.length lines then acc
    else
      let line = String.trim lines.(r - 1) in
      if String.length line >= 2 && String.sub line 0 2 = "##" then
        let body = String.sub line 2 (String.length line - 2) in
        let body = if String.length body > 0 && body.[0] = ' ' then String.sub body 1 (String.length body - 1) else body in
        go (r - 1) (body :: acc)
      else acc
  in
  match go (row - 1) [] with
  | [] -> None
  | lines -> Some (String.concat "\n" (section_labels lines))

(** The unit an analysis holds for a document, and its types.
    analysis -> document -> (Module.t, typ IntMap.t)? *)
let own_unit analysis document =
  List.find_opt (fun (u : Module.t) -> u.path = document.path) analysis.units
  |> Option.map (fun (u : Module.t) ->
         (u, Option.value ~default:IntMap.empty (List.assoc_opt u.path analysis.tmaps)))

(** A type as Pyking writes it. typ -> string *)
let show_type t = pprint_type default_config t

(** The type the checker recorded for a binding, or, for a name another
    module exports, the type it exports it at. analysis -> meaning ->
    string? *)
let meaning_type analysis meaning =
  match meaning with
  | Bound (place, s, _) -> (
      let recorded =
        if s = 0 then None
        else
          List.find_map
            (fun (_, tmap) -> IntMap.find_opt s tmap)
            (List.filter (fun (p, _) -> p = place.file) analysis.tmaps)
      in
      match recorded with
      | Some t -> Some (show_type t)
      | None ->
          let owner =
            List.find_opt
              (fun (u : Module.t) -> u.path = place.file || u.declaration_path = Some place.file)
              analysis.units
          in
          Option.bind owner (fun (u : Module.t) ->
              Option.bind (List.assoc_opt u.name analysis.sigmaps) (fun sigmap ->
                  List.find_map
                    (fun (n, t, _) ->
                      match export_place u n with
                      | Some (p, _, _) when p.span = place.span -> Some (show_type t)
                      | _ -> None)
                    sigmap)))
  | _ -> None

(** The smallest node in a module holding a position whose type the
    checker recorded: an expression, a binding's target, a parameter, or
    a definition's first line -- with the name it binds, where it binds
    one. [stmt] -> typ IntMap.t -> int -> int -> (Lexer.info, typ,
    string?)? *)
let typed_node stmts tmap row col =
  let candidate node =
    match node with
    | Walk.NExpr e -> Some (expr_info e, expr_sym e, None)
    | Walk.NTarget (TargetName (i, n, s)) -> Some (i, s, Some n)
    | Walk.NTarget t -> Some (target_info t, target_sym t, None)
    | Walk.NParam (Param (i, n, _, _, s)) -> Some (i, s, Some n)
    | Walk.NStmt (SFunctionDef (i, n, _, _, _, s, _, _, _)) when i.row1 = row ->
        Some ({ i with row2 = i.row1; col2 = max_int }, s, Some ("def " ^ n))
    | Walk.NStmt (SVar (i, n, _, s)) when i.row1 = row ->
        Some ({ i with row2 = i.row1; col2 = i.col1 + String.length "var " + String.length n }, s, Some ("var " ^ n))
    | _ -> None
  in
  Walk.fold_stmts
    (fun best node ->
      match candidate node with
      | Some (i, s, name) when contains i row col -> (
          match IntMap.find_opt s tmap with
          | Some t -> (
              match best with
              | Some (b, _, _) when compare (size b) (size i) <= 0 -> best
              | _ -> Some (i, t, name))
          | None -> best)
      | _ -> best)
    None stmts

(** A Markdown hover holding Pyking. string -> string? -> Json.t *)
let hover_contents code doc =
  Json.Object
    [
      ("kind", Json.String "markdown");
      ( "value",
        Json.String
          ("```pyking\n" ^ code ^ "\n```" ^ match doc with Some d -> "\n\n" ^ d | None -> "") );
    ]

(** The hover at a position of a document. state -> document -> Json.t ->
    (state, Json.t) *)
let hover state document pos =
  let state, analysis = analysis_of state document in
  let row, col = row_col document.text pos in
  let typed_analysis =
    match analysis.typed with Some (units, tmaps) -> { analysis with units; tmaps } | None -> analysis
  in
  match own_unit typed_analysis document with
  | None -> (state, Json.Null)
  | Some (unit, tmap) -> (
      let analysis = typed_analysis in
      let found = resolve analysis.units unit in
      let use = use_at found row col in
      let doc =
        match use with
        | Some { use_meaning = Bound (place, _, _); _ } -> doc_comment state place.file place.span.row1
        | _ -> None
      in
      match use with
      | Some { use_name; use_meaning = Builtin; use_at } ->
          (state, Json.Object [ ("contents", hover_contents (use_name ^ " -- builtin") None); ("range", range document.text use_at) ])
      | Some { use_name; use_meaning = Module_of real; use_at } ->
          (state, Json.Object [ ("contents", hover_contents ("import " ^ real ^ (if real = use_name then "" else " as " ^ use_name)) None); ("range", range document.text use_at) ])
      | _ -> (
          match typed_node unit.stmts tmap row col with
          | Some (i, t, name) ->
              let label =
                match (use, name) with
                | Some u, _ when compare (size u.use_at) (size i) <= 0 -> u.use_name ^ ": "
                | _, Some n -> n ^ ": "
                | _ -> ""
              in
              let shown = { i with col2 = (if i.col2 = max_int then String.length (line_at document.text i.row1) else i.col2) } in
              (state, Json.Object [ ("contents", hover_contents (label ^ show_type t) doc); ("range", range document.text shown) ])
          | None -> (
              match use with
              | Some u -> (
                  match meaning_type analysis u.use_meaning with
                  | Some t -> (state, Json.Object [ ("contents", hover_contents (u.use_name ^ ": " ^ t) doc) ])
                  | None -> (state, Json.Null))
              | None -> (state, Json.Null))))

(** An LSP location for a place. state -> place -> Json.t *)
let location state place =
  Json.Object [ ("uri", Json.String (uri_of_path place.file)); ("range", range (text_of state place.file) place.span) ]

(** Where the name at a position of a document is bound.
    state -> document -> Json.t -> (state, Json.t) *)
let definition state document pos =
  let state, analysis = analysis_of state document in
  let row, col = row_col document.text pos in
  match own_unit analysis document with
  | None -> (state, Json.Null)
  | Some (unit, _) -> (
      let found = resolve analysis.units unit in
      match use_at found row col with
      | Some { use_meaning = Bound (place, _, _); _ } -> (state, location state place)
      | Some { use_meaning = Module_of real; _ } -> (
          match List.find_opt (fun (u : Module.t) -> u.name = real) analysis.units with
          | Some u ->
              let file = if u.is_external then Option.value ~default:u.path u.declaration_path else u.path in
              (state, location state { file; span = { file; row1 = 1; col1 = 0; row2 = 1; col2 = 0 } })
          | None -> (state, Json.Null))
      | _ -> (state, Json.Null))

(** One DocumentSymbol. string -> int -> string -> Lexer.info ->
    Lexer.info -> string? -> [Json.t] -> Json.t *)
let symbol text kind name (whole : Lexer.info) (selection : Lexer.info) detail children =
  Json.Object
    ([ ("name", Json.String name); ("kind", Json.Number (float_of_int kind));
       ("range", range text whole); ("selectionRange", range text selection) ]
    @ (match detail with Some d -> [ ("detail", Json.String d) ] | None -> [])
    @ if children = [] then [] else [ ("children", Json.List children) ])

(** The outline of a document: its definitions, nested ones inside, its
    top-level bindings and its imports. state -> document -> (state, Json.t) *)
let document_symbols state document =
  let state, analysis = analysis_of state document in
  match own_unit analysis document with
  | None -> (state, Json.List [])
  | Some (unit, tmap) ->
      let text = document.text in
      let typed s = Option.map show_type (IntMap.find_opt s tmap) in
      let rec of_stmts top stmts =
        List.concat_map
          (fun stmt ->
            match stmt with
            | SFunctionDef (i, n, _, body, _, s, _, _, _) ->
                [ symbol text 12 n i (name_span unit.tokens n i) (typed s) (of_stmts false body) ]
            | SLet (i, target, _, _, _, _, _) when top ->
                List.map (fun (n, span, s) -> symbol text 14 n i span (typed s) []) (target_bindings target)
            | SLetStmt (i, target, _, _, _, _) when top ->
                List.map (fun (n, span, s) -> symbol text 14 n i span (typed s) []) (target_bindings target)
            | SVar (i, n, _, _) when top -> [ symbol text 13 n i (name_span unit.tokens n i) None [] ]
            | SImport (i, module_, name, selected, fields, _) ->
                if selected then
                  List.map (fun (_, local) -> symbol text 2 local i (name_span unit.tokens local i) (Some ("from " ^ module_)) []) fields
                else [ symbol text 2 name i (name_span unit.tokens name i) (Some ("import " ^ module_)) [] ]
            | _ -> [])
          stmts
      in
      (state, Json.List (of_stmts true unit.stmts))

(** A completion item. string -> int -> string? -> Json.t *)
let item label kind detail =
  Json.Object
    ([ ("label", Json.String label); ("kind", Json.Number (float_of_int kind)) ]
    @ match detail with Some d -> [ ("detail", Json.String d) ] | None -> [])

let hidden = Completion.hidden
let qualifier = Completion.qualifier

(** Whether a plain name is in a submodule further down: it holds a
    `__`. string -> bool *)
let nested name =
  let rec at i = i + 1 < String.length name && ((name.[i] = '_' && name.[i + 1] = '_') || at (i + 1)) in
  at 0

(** Completion items, each label once, the first kept. [Json.t] -> [Json.t] *)
let distinct items =
  let label i = match Json.member "label" i with Json.String l -> l | _ -> "" in
  List.rev
    (fst
       (List.fold_left
          (fun (kept, seen) i -> if List.mem (label i) seen then (kept, seen) else (i :: kept, label i :: seen))
          ([], []) items))

(** What a module offers after `m.` and the submodules in `path`: its
    members there, and the submodules one level further down, each once.
    [(string, typ, _)] -> [(string, string)] -> [string] -> [Json.t] *)
let submodule_items sigmap dotted path =
  let prefix = if path = [] then "" else String.concat "." path ^ "." in
  let n = String.length prefix in
  let public plain = List.find_opt (fun (p, _, _) -> p = plain) sigmap in
  let typed name plain =
    match public plain with
    | Some (_, t, _) -> Some (item name (match t with TFunction _ -> 3 | _ -> 6) (Some (show_type t)))
    | None -> None
  in
  let below =
    List.filter_map
      (fun (name, plain) ->
        if String.length name > n && String.sub name 0 n = prefix then
          let rest = String.sub name n (String.length name - n) in
          match String.index_opt rest '.' with
          | Some k -> if public plain = None then None else Some (`Sub (String.sub rest 0 k))
          | None -> Option.map (fun i -> `Item (rest, i)) (typed rest plain)
        else None)
      dotted
  in
  let subs = List.sort_uniq compare (List.filter_map (function `Sub s -> Some s | `Item _ -> None) below) in
  let members = List.filter_map (function `Item (_, i) -> Some i | `Sub _ -> None) below in
  let plains = List.map snd dotted in
  let own =
    if path <> [] then []
    else
      List.filter_map
        (fun (name, t, _) ->
          if hidden name || List.mem name plains then None
          else Some (item name (match t with TFunction _ -> 3 | _ -> 6) (Some (show_type t))))
        sigmap
  in
  distinct (List.map (fun sub -> item sub 9 (Some "submodule")) subs @ own @ members)

(** What may be written at a position of a document: after `m.`, what
    module m exports; elsewhere the names in scope there, the keywords
    and the builtins. state -> document -> Json.t -> (state, Json.t) *)
let completion state document pos =
  let state, analysis = analysis_of state document in
  let row, col = row_col document.text pos in
  let found = Option.map (fun (u, _) -> resolve analysis.units u) (own_unit analysis document) in
  let scope_names =
    match found with None -> SMap.empty | Some found -> names_at found row col
  in
  let module_names =
    List.fold_left (fun env (u : Module.t) -> SMap.add u.name (Module_of u.name) env) SMap.empty analysis.units
  in
  match qualifier (line_at document.text row) col with
  | Some chain ->
      let m, path =
        match String.split_on_char '.' chain with m :: path -> (m, path) | [] -> (chain, [])
      in
      let real =
        match SMap.find_opt m scope_names with
        | Some (Module_of real) -> Some real
        | _ -> (match SMap.find_opt m module_names with Some (Module_of r) -> Some r | _ -> None)
      in
      let items =
        match (real, Option.bind real (fun r -> List.assoc_opt r analysis.sigmaps)) with
        | Some r, Some sigmap ->
            let dotted =
              match List.find_opt (fun (u : Module.t) -> u.name = r) analysis.units with
              | Some u -> u.dotted
              | None -> []
            in
            submodule_items sigmap dotted path
        | _ ->
            (* A submodule imported under a name of its own: its members
               are in scope under the plain names they compile to,
               `shapes__size` and, for a type, `Shapes__Box`. *)
            let flat = String.concat "__" (String.split_on_char '.' chain) ^ "__" in
            let prefixes = [ flat; String.capitalize_ascii flat ] in
            SMap.fold
              (fun name meaning acc ->
                match
                  List.find_opt
                    (fun p -> String.length name > String.length p && String.sub name 0 (String.length p) = p)
                    prefixes
                with
                | Some p ->
                    let rest = String.sub name (String.length p) (String.length name - String.length p) in
                    if hidden name || nested rest then acc
                    else
                      item rest (match meaning with Bound (_, _, KFunction) -> 3 | _ -> 6) (meaning_type analysis meaning)
                      :: acc
                | None -> acc)
              scope_names []
            |> List.rev
            |> distinct
      in
      (state, Json.Object [ ("isIncomplete", Json.Bool false); ("items", Json.List items) ])
  | None ->
      let names =
        SMap.fold
          (fun n meaning acc ->
            if String.contains n '.' || hidden n then acc
            else
              let kind, detail =
                match meaning with
                | Builtin -> (3, Some "builtin")
                | Module_of real -> (9, Some ("module " ^ real))
                | Bound (_, _, KFunction) -> (3, meaning_type analysis meaning)
                | Bound (_, _, KVariable) -> (6, Option.map (fun t -> "var " ^ t) (meaning_type analysis meaning))
                | Bound _ -> (6, meaning_type analysis meaning)
                | Unknown -> (6, None)
              in
              item n kind detail :: acc)
          scope_names []
      in
      let names = if names = [] then List.map (fun n -> item n 3 (Some "builtin")) Builtin.names else names in
      (* A reserved word nothing uses yet is no keyword to offer. *)
      let keywords =
        List.map (fun k -> item k 14 None)
          (List.filter (fun k -> not (List.mem k Lexer.reserved_words)) Lexer.keywords)
      in
      (state, Json.Object [ ("isIncomplete", Json.Bool false); ("items", Json.List (List.rev names @ keywords)) ])

(* --- signature help --- *)

(** The call a position is inside, read from the text, since a call being
    typed seldom parses: the callee written before the innermost `(`
    still open there, the row and byte column of that callee, how many
    commas at its depth come before the position, and the name of a
    named argument being written. string -> int -> int -> (string, int,
    int, int, string?)? *)
let open_call text row col =
  let at = offset_of text row col in
  let rec back i depth commas =
    if i < 0 || at - i > 4000 then None
    else
      match text.[i] with
      | ')' | ']' -> back (i - 1) (depth + 1) commas
      | '[' -> if depth = 0 then None else back (i - 1) (depth - 1) commas
      | '(' -> if depth = 0 then Some (i, commas) else back (i - 1) (depth - 1) commas
      | ',' when depth = 0 -> back (i - 1) depth (commas + 1)
      | _ -> back (i - 1) depth commas
  in
  match back (at - 1) 0 0 with
  | None -> None
  | Some (paren, commas) -> (
      let is_name c =
        match c with 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '.' | ':' -> true | _ -> false
      in
      let rec start i = if i > 0 && is_name text.[i - 1] then start (i - 1) else i in
      let first = start paren in
      let callee = String.sub text first (paren - first) in
      if callee = "" || not (match callee.[0] with 'a' .. 'z' | 'A' .. 'Z' | '_' -> true | _ -> false)
      then None
      else
        (* The argument being written: after the last comma or the `(`. *)
        let rec last_comma i depth =
          if i <= paren then paren
          else
            match text.[i] with
            | ')' | ']' -> last_comma (i - 1) (depth + 1)
            | '(' | '[' -> last_comma (i - 1) (depth - 1)
            | ',' when depth = 0 -> i
            | _ -> last_comma (i - 1) depth
        in
        let from = last_comma (at - 1) 0 + 1 in
        let argument = String.trim (String.sub text from (max 0 (at - from))) in
        let named =
          match String.index_opt argument '=' with
          | Some k
            when k > 0
                 && (k + 1 >= String.length argument || argument.[k + 1] <> '=')
                 && argument.[k - 1] <> '=' && argument.[k - 1] <> '<' && argument.[k - 1] <> '>'
                 && argument.[k - 1] <> ':' ->
              let name = String.trim (String.sub argument 0 k) in
              if name <> "" && String.for_all (fun c -> is_name c && c <> '.' && c <> ':') name then Some name
              else None
          | _ -> None
        in
        let rec position_of offset r c i =
          if i >= offset then (r, c)
          else if text.[i] = '\n' then position_of offset (r + 1) 0 (i + 1)
          else position_of offset r (c + 1) (i + 1)
        in
        let r, c = position_of first 1 0 0 in
        Some (callee, r, c, commas, named))

(** The `##` comment above a row of a file, as its lines, without their
    markers. state -> string -> int -> [string] *)
let doc_lines state file row =
  let lines = Array.of_list (lines_of (text_of state file)) in
  let rec go r acc =
    if r < 1 || r > Array.length lines then acc
    else
      let line = String.trim lines.(r - 1) in
      if String.length line >= 2 && String.sub line 0 2 = "##" then
        let body = String.sub line 2 (String.length line - 2) in
        let body = if String.length body > 0 && body.[0] = ' ' then String.sub body 1 (String.length body - 1) else body in
        go (r - 1) (body :: acc)
      else acc
  in
  go (row - 1) []

(** A doc comment's summary -- what comes before its first `#` section
    -- and what its `# Parameters` section says of each parameter.
    [string] -> (string, [(string, string)]) *)
let doc_parts lines =
  let is_section line = String.length line > 2 && String.sub line 0 2 = "# " in
  let rec summary lines out =
    match lines with
    | line :: rest when not (is_section line) -> summary rest (out @ [ line ])
    | _ -> String.trim (String.concat "\n" out)
  in
  let rec parameters lines inside out =
    match lines with
    | [] -> out
    | line :: rest when is_section line -> parameters rest (String.trim line = "# Parameters") out
    | line :: rest when inside && String.length line > 2 && String.sub line 0 2 = "- " -> (
        let item = String.sub line 2 (String.length line - 2) in
        match String.index_opt item ':' with
        | Some k ->
            let name = String.trim (String.sub item 0 k) in
            let name =
              if String.length name >= 2 && name.[0] = '`' && name.[String.length name - 1] = '`'
              then String.sub name 1 (String.length name - 2)
              else name
            in
            parameters rest inside (out @ [ (name, String.trim (String.sub item (k + 1) (String.length item - k - 1))) ])
        | None -> parameters rest inside out)
    | line :: rest when inside && out <> [] && String.length line > 0 && line.[0] = ' ' ->
        let name, text = List.nth out (List.length out - 1) in
        parameters rest inside (List.filteri (fun k _ -> k < List.length out - 1) out @ [ (name, text ^ " " ^ String.trim line) ])
    | _ :: rest -> parameters rest inside out
  in
  (summary lines [], parameters lines false [])

(** The definition a binding's place names, in the units of a program.
    [Module.t] -> place -> stmt? *)
let definition_at units (place : place) =
  List.find_map
    (fun (u : Module.t) ->
      if u.path <> place.file && u.declaration_path <> Some place.file then None
      else
        Walk.fold_stmts
          (fun found node ->
            match (found, node) with
            | None, Walk.NStmt (SFunctionDef (i, n, _, _, _, _, _, _, _) as d)
              when name_span u.tokens n i = place.span ->
                Some d
            | None, Walk.NStmt (SFunctionSig (i, _, _, _, _) as d) when i = place.span -> Some d
            | _ -> found)
          None (u.stmts @ u.declarations))
    units

(** One signature: its label, its documentation, and each parameter's
    span in the label and documentation. string -> string -> [(string,
    string)] -> Json.t *)
let signature label doc params =
  let utf16 text = utf16_of_bytes text (String.length text) in
  let _, parameters =
    List.fold_left
      (fun (from, out) (shown, about) ->
        let rec find i =
          if i + String.length shown > String.length label then None
          else if String.sub label i (String.length shown) = shown then Some i
          else find (i + 1)
        in
        match find from with
        | None -> (from, out)
        | Some i ->
            let a = utf16 (String.sub label 0 i) and b = utf16 (String.sub label 0 (i + String.length shown)) in
            ( i + String.length shown,
              out
              @ [
                  Json.Object
                    ([ ("label", Json.List [ Json.Number (float_of_int a); Json.Number (float_of_int b) ]) ]
                    @ if about = "" then [] else [ ("documentation", Json.String about) ]);
                ] ))
      (String.index_opt label '(' |> Option.value ~default:0, [])
      params
  in
  Json.Object
    ([ ("label", Json.String label); ("parameters", Json.List parameters) ]
    @ if doc = "" then [] else [ ("documentation", Json.Object [ ("kind", Json.String "markdown"); ("value", Json.String doc) ]) ])

(** The signatures of a builtin, each its label and parameters.
    string -> [(string, [string])] *)
let builtin_signatures name =
  match name with
  | "print" | "debug" -> [ (name ^ "(values...) -> ()", [ "values..." ]) ]
  | "range" ->
      [
        ("range(stop: Int) -> [Int]", [ "stop: Int" ]);
        ("range(start: Int, stop: Int) -> [Int]", [ "start: Int"; "stop: Int" ]);
        ("range(start: Int, stop: Int, step: Int) -> [Int]", [ "start: Int"; "stop: Int"; "step: Int" ]);
      ]
  | "len" -> [ ("len(items) -> Int", [ "items" ]) ]
  | "string" -> [ ("string(value) -> String", [ "value" ]) ]
  | "int" -> [ ("int(value) -> Int", [ "value" ]) ]
  | "float" -> [ ("float(value) -> Float", [ "value" ]) ]
  | "bool" -> [ ("bool(value) -> Bool", [ "value" ]) ]
  | _ -> []

(** The signature of a definition: `name(p: T, ...) -> R`, with what its
    `##` comment says, and its parameters' names.
    state -> analysis -> string -> place -> int -> (Json.t, [string])? *)
let def_signature state analysis shown (place : place) sym =
  let types = meaning_type analysis (Bound (place, sym, KFunction)) in
  let doc, about = doc_parts (doc_lines state place.file place.span.row1) in
  match definition_at analysis.units place with
  | Some (SFunctionDef (_, _, params, _, ret, s, _, implicits, _)) ->
      let tmap =
        Option.value ~default:IntMap.empty (List.assoc_opt place.file analysis.tmaps)
      in
      let param_type (Param (_, _, written, _, ps)) =
        match IntMap.find_opt ps tmap with
        | Some t -> Some (show_type t)
        | None -> Option.map show_type written
      in
      let shown_params =
        List.map
          (fun (Param (_, n, _, default, _) as p) ->
            n ^ (match param_type p with Some t -> ": " ^ t | None -> "")
            ^ if default <> None then " = ..." else "")
          params
      in
      let result =
        match IntMap.find_opt s tmap with
        | Some (TFunction (_, _, r, _, _, _, _)) -> " -> " ^ show_type r
        | _ -> ( match ret with Some r -> " -> " ^ show_type r | None -> "")
      in
      let implicit_part =
        if implicits = [] then ""
        else
          ", "
          ^ String.concat ", "
              (List.map (fun (Param (_, n, w, _, _)) -> "implicit " ^ n ^ match w with Some t -> ": " ^ show_type t | None -> "") implicits)
      in
      let label = shown ^ "(" ^ String.concat ", " shown_params ^ implicit_part ^ ")" ^ result in
      let names = List.map (fun (Param (_, n, _, _, _)) -> n) params in
      Some
        ( signature label doc
            (List.map2 (fun shown_p n -> (shown_p, Option.value ~default:"" (List.assoc_opt n about))) shown_params names),
          names )
  | _ -> (
      (* A declaration: only its type is known. *)
      match types with
      | Some t ->
          let label = shown ^ " : " ^ t in
          Some (signature label doc [], [])
      | None -> None)

(** The signatures of the call a position is inside, the one meant
    first, and the parameter being written.
    state -> document -> Json.t -> (state, Json.t) *)
let signature_help state document pos =
  let state, analysis = analysis_of state document in
  let row, col = row_col document.text pos in
  let typed = match analysis.typed with Some (units, tmaps) -> { analysis with units; tmaps } | None -> analysis in
  match (open_call document.text row col, own_unit typed document) with
  | None, _ | _, None -> (state, Json.Null)
  | Some (callee, r, c, commas, named), Some (unit, _) ->
      let found = resolve typed.units unit in
      let names = names_at found r c in
      let module_, base =
        match String.rindex_opt callee '.' with
        | Some k -> (Some (String.sub callee 0 k), String.sub callee (k + 1) (String.length callee - k - 1))
        | None -> (None, callee)
      in
      let candidates =
        match module_ with
        | Some m -> (
            let real =
              match SMap.find_opt m names with
              | Some (Module_of real) -> Some real
              | _ -> if List.exists (fun (u : Module.t) -> u.name = m) typed.units then Some m else None
            in
            match Option.bind real (fun r -> List.find_opt (fun (u : Module.t) -> u.name = r) typed.units) with
            | None -> []
            | Some u ->
                List.filter_map
                  (fun (n, _) ->
                    if n = base || (Names.is_qualified n && Names.base n = base) then
                      Option.map (fun (place, s, _) -> (m ^ "." ^ n, place, s)) (export_place u n)
                    else None)
                  u.publics)
        | None ->
            SMap.fold
              (fun n meaning out ->
                match meaning with
                | Bound (place, s, _) when n = base || (Names.is_qualified n && Names.base n = base) ->
                    out @ [ (n, place, s) ]
                | _ -> out)
              names []
      in
      let built =
        List.filter_map (fun (shown, place, s) -> def_signature state typed shown place s) candidates
      in
      let built =
        if built <> [] then built
        else
          (* A constructor: its fields, as its datatype writes them. *)
          List.concat_map
            (fun (u : Module.t) ->
              Walk.fold_stmts
                (fun out node ->
                  match node with
                  | Walk.NConstructor (Constructor (_, n, fields, _)) when n = base ->
                      let shown =
                        List.mapi
                          (fun k (Field (_, label, written, default, _)) ->
                            Option.value ~default:(string_of_int k) label
                            ^ (match written with Some t -> ": " ^ show_type t | None -> "")
                            ^ if default <> None then " = ..." else "")
                          fields
                      in
                      let names =
                        List.mapi (fun k (Field (_, label, _, _, _)) -> Option.value ~default:(string_of_int k) label) fields
                      in
                      out @ [ (signature (n ^ "(" ^ String.concat ", " shown ^ ")") "" (List.map (fun p -> (p, "")) shown), names) ]
                  | _ -> out)
                [] u.stmts)
            (if String.length base > 0 && base.[0] >= 'A' && base.[0] <= 'Z' then typed.units else [])
      in
      let built =
        if built <> [] then built
        else
          match SMap.find_opt base names with
          | Some Builtin | None when module_ = None ->
              List.map
                (fun (label, params) ->
                  let doc = match Builtin.lookup base with Some b -> b.doc | None -> "" in
                  (signature label doc (List.map (fun p -> (p, "")) params), []))
                (builtin_signatures base)
          | _ -> []
      in
      if built = [] then (state, Json.Null)
      else
        let active_parameter names =
          match named with
          | Some n -> (
              match List.find_index (fun x -> x = n) names with Some k -> k | None -> commas)
          | None -> commas
        in
        (* The signature meant first is the first with room for the
           arguments written so far. *)
        let active =
          match
            List.find_index
              (fun (s, _) -> List.length (Json.to_list (Json.member "parameters" s)) > commas)
              built
          with
          | Some k -> k
          | None -> 0
        in
        let _, names_active = List.nth built active in
        ( state,
          Json.Object
            [
              ("signatures", Json.List (List.map fst built));
              ("activeSignature", Json.Number (float_of_int active));
              ("activeParameter", Json.Number (float_of_int (active_parameter names_active)));
            ] )

(* --- references, highlights and renaming --- *)

(** The binding a position names in a document: the one a use there
    reaches, or the one written there; with the name as written at the
    position. analysis -> document -> int -> int -> (place, int,
    binding_kind, string)? *)
let binding_at analysis document row col =
  match own_unit analysis document with
  | None -> None
  | Some (unit, _) -> (
      let found = resolve analysis.units unit in
      match use_at found row col with
      | Some { use_meaning = Bound (place, s, kind); use_name; _ } ->
          let name =
            match String.rindex_opt use_name '.' with
            | Some k -> String.sub use_name (k + 1) (String.length use_name - k - 1)
            | None -> use_name
          in
          Some (place, s, kind, name)
      | _ ->
          List.find_map
            (fun (n, (place : place), s, kind) ->
              if place.file = document.path && contains place.span row col then Some (place, s, kind, n) else None)
            (bindings found))

(** Every place a binding is written: its own, then each use of it in
    every module of the program, each with whether it is the binding.
    analysis -> place -> [(string, Lexer.info, bool)] *)
let occurrences analysis (place : place) =
  let same (p : place) = p.file = place.file && p.span = place.span in
  let uses =
    List.concat_map
      (fun (u : Module.t) ->
        if u.is_external then []
        else
          let found = resolve analysis.units u in
          List.filter_map
            (fun use ->
              match use.use_meaning with
              | Bound (p, _, _) when same p && not (use.use_at = place.span && u.path = place.file) ->
                  Some (u.path, use.use_at, false)
              | _ -> None)
            found.uses)
      analysis.units
  in
  let uses = List.sort_uniq compare uses in
  (place.file, place.span, true) :: uses

(** Every place the name at a position is written, as locations.
    state -> document -> Json.t -> bool -> (state, Json.t) *)
let references state document pos declaration =
  let state, analysis = analysis_of state document in
  (* Names and where they are written come from the text as it is now. *)
  let row, col = row_col document.text pos in
  match binding_at analysis document row col with
  | None -> (state, Json.Null)
  | Some (place, _, _, _) ->
      ( state,
        Json.List
          (List.filter_map
             (fun (file, span, own) ->
               if own && not declaration then None else Some (location state { file; span }))
             (occurrences analysis place)) )

(** Where in this document the name at a position is written: the
    binding as written to, each use as read. state -> document -> Json.t
    -> (state, Json.t) *)
let highlights state document pos =
  let state, analysis = analysis_of state document in
  (* Names and where they are written come from the text as it is now. *)
  let row, col = row_col document.text pos in
  match binding_at analysis document row col with
  | None -> (state, Json.Null)
  | Some (place, _, _, _) ->
      ( state,
        Json.List
          (List.filter_map
             (fun (file, span, own) ->
               if file <> document.path then None
               else
                 Some
                   (Json.Object
                      [ ("range", range document.text span); ("kind", Json.Number (if own then 3. else 2.)) ]))
             (occurrences analysis place)) )

(** Why the name at a position cannot be renamed, or the binding, the
    name and every place it is written.
    state -> analysis -> document -> int -> int -> (string, (place,
    string, [(string, Lexer.info, bool)])) result *)
let renamable state analysis document row col =
  match binding_at analysis document row col with
  | None -> Error "there is no name here to rename"
  | Some (place, _, _, name) ->
      let all = occurrences analysis place in
      if Names.is_qualified name || String.contains name ':' then
        Error "a name with a qualifier is one of an overloaded set: rename it where it is defined, by hand"
      else if List.exists (fun (file, _, _) -> Module.in_library state.libs file) all then
        Error ("'" ^ name ^ "' is a library's, and a library is not renamed from here")
      else Ok (place, name, all)

(** The span of the name under a position, for an editor to edit, with
    the name. state -> document -> Json.t -> (state, (Json.t, (int,
    string)) result) *)
let prepare_rename state document pos =
  let state, analysis = analysis_of state document in
  (* Names and where they are written come from the text as it is now. *)
  let row, col = row_col document.text pos in
  match renamable state analysis document row col with
  | Error why -> (state, Error (-32602, why))
  | Ok (_, name, all) -> (
      match
        List.find_opt (fun (file, span, _) -> file = document.path && contains span row col) all
      with
      | Some (_, span, _) ->
          (state, Ok (Json.Object [ ("range", range document.text span); ("placeholder", Json.String name) ]))
      | None -> (state, Error (-32602, "there is no name here to rename")))

(** Whether a text is a name a program may bind. string -> bool *)
let bindable name =
  String.length name > 0
  && (match name.[0] with 'a' .. 'z' | '_' -> true | _ -> false)
  && String.for_all (function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true | _ -> false) name
  && (not (List.mem name Lexer.keywords))
  && not (List.mem name Builtin.names)

(** Every place the name at a position is written, given a new name --
    refused where the new name is not one a program may bind, or where
    it would mean something else at any of those places.
    state -> document -> Json.t -> string -> (state, (Json.t, (int,
    string)) result) *)
let rename state document pos new_name =
  let state, analysis = analysis_of state document in
  (* Names and where they are written come from the text as it is now. *)
  let row, col = row_col document.text pos in
  match renamable state analysis document row col with
  | Error why -> (state, Error (-32602, why))
  | Ok (place, name, all) ->
      if not (bindable new_name) then
        (state, Error (-32602, Printf.sprintf "'%s' is not a name a program can bind" new_name))
      else
        let clash =
          List.find_map
            (fun (file, (span : Lexer.info), _) ->
              match List.find_opt (fun (u : Module.t) -> u.path = file) analysis.units with
              | None -> None
              | Some u -> (
                  let found = resolve analysis.units u in
                  match SMap.find_opt new_name (names_at found span.row1 span.col1) with
                  | Some (Bound (p, _, _)) when p <> place -> Some (file, span)
                  | Some Builtin | Some (Module_of _) -> Some (file, span)
                  | _ -> None))
            all
        in
        match clash with
        | Some (file, span) ->
            ( state,
              Error
                ( -32602,
                  Printf.sprintf "'%s' is already a name in scope at %s %d:%d, so the rename would change what it means"
                    new_name (Filename.basename file) span.row1 (span.col1 + 1) ) )
        | None ->
            let edits =
              List.fold_left
                (fun edits (file, (span : Lexer.info), _) ->
                  let text = text_of state file in
                  let line = line_at text span.row1 in
                  let written =
                    if span.row1 = span.row2 && span.col2 <= String.length line then
                      String.sub line span.col1 (span.col2 - span.col1)
                    else ""
                  in
                  (* An alias that happens to point here is a name of its
                     own, and keeps it. *)
                  if written <> name then edits
                  else
                    let edit =
                      Json.Object [ ("range", range text span); ("newText", Json.String new_name) ]
                    in
                    let uri = uri_of_path file in
                    match List.assoc_opt uri edits with
                    | Some list -> (uri, list @ [ edit ]) :: List.remove_assoc uri edits
                    | None -> edits @ [ (uri, [ edit ]) ])
                [] all
            in
            ( state,
              Ok
                (Json.Object
                   [ ("changes", Json.Object (List.map (fun (u, es) -> (u, Json.List es)) edits)) ]) )

(* --- inlay hints --- *)

(** The type the checker worked out for every binding a document did not
    annotate, shown after its name, and for every definition that did
    not say what it returns, after its parameters.
    state -> document -> Json.t -> (state, Json.t) *)
let inlay_hints state document range_ =
  let state, analysis = analysis_of state document in
  let analysis = match analysis.typed with Some (units, tmaps) -> { analysis with units; tmaps } | None -> analysis in
  match own_unit analysis document with
  | None -> (state, Json.List [])
  | Some (unit, tmap) when state.settings.inlay_hints ->
      let first, _ = row_col document.text (Json.member "start" range_) in
      let last, _ = row_col document.text (Json.member "end" range_) in
      let hint row col label left =
        Json.Object
          ([ ("position", position document.text row col); ("label", Json.String label); ("kind", Json.Number 1.) ]
          @ if left then [ ("paddingLeft", Json.Bool true) ] else [])
      in
      let typed s = Option.map show_type (IntMap.find_opt s tmap) in
      let after (i : Lexer.info) s =
        match typed s with Some t -> [ (i.row2, i.col2, ": " ^ t, false) ] | None -> []
      in
      let rec target_hints target =
        match target with
        | TargetName (i, _, s) -> after i s
        | TargetTuple (_, targets, _) -> List.concat_map target_hints targets
      in
      let param_hints params =
        List.concat_map
          (fun (Param (i, n, written, _, s)) ->
            if written <> None then []
            else after { i with row2 = i.row1; col2 = i.col1 + String.length n } s)
          params
      in
      (* Where a definition's parameter list closes: the `)` matching the
         first `(` after its name. *)
      let closing (i : Lexer.info) =
        let rec go tokens depth started =
          match tokens with
          | [] -> None
          | Lexer.TokLParen t :: rest when compare (t.row1, t.col1) (i.row1, i.col1) >= 0 ->
              go rest (depth + 1) true
          | Lexer.TokRParen t :: rest when started ->
              if depth = 1 then Some t else go rest (depth - 1) started
          | _ :: rest -> go rest depth started
        in
        go unit.tokens 0 false
      in
      let hints =
        Walk.fold_stmts
          (fun out node ->
            match node with
            | Walk.NStmt (SLet (_, target, _, None, _, _, _)) | Walk.NStmt (SLetStmt (_, target, _, None, _, _)) ->
                out @ target_hints target
            | Walk.NStmt (SLoop (_, Some target, _, None, _, _, _)) -> out @ target_hints target
            | Walk.NStmt (SVar (i, n, _, s)) ->
                let span = name_span unit.tokens n i in
                out @ after span s
            | Walk.NStmt (SFunctionDef (i, _, params, _, ret, s, _, _, _)) ->
                let returns =
                  match (ret, IntMap.find_opt s tmap, closing i) with
                  | None, Some (TFunction (_, _, r, _, _, _, _)), Some paren ->
                      [ (paren.row2, paren.col2, "-> " ^ show_type r, true) ]
                  | _ -> []
                in
                out @ param_hints params @ returns
            | Walk.NExpr (ELambda (_, params, _, _)) -> out @ param_hints params
            | _ -> out)
          [] unit.stmts
      in
      ( state,
        Json.List
          (List.filter_map
             (fun (row, col, label, left) ->
               if row >= first && row <= last then Some (hint row col label left) else None)
             hints) )
  | Some _ -> (state, Json.List [])

(* --- folding --- *)

(** The parts of a document that fold: every block that spans lines, each
    run of comment lines, and the imports at its top.
    state -> document -> (state, Json.t) *)
let folding_ranges state document =
  let state, analysis = analysis_of state document in
  (* Names and where they are written come from the text as it is now. *)
  let range_json first last kind =
    Json.Object
      ([ ("startLine", Json.Number (float_of_int (first - 1))); ("endLine", Json.Number (float_of_int (last - 1))) ]
      @ match kind with Some k -> [ ("kind", Json.String k) ] | None -> [])
  in
  let blocks =
    match own_unit analysis document with
    | None -> []
    | Some (unit, _) ->
        Walk.fold_stmts
          (fun out node ->
            let span =
              match node with
              | Walk.NStmt (SFunctionDef (i, _, _, _, _, _, _, _, _))
              | Walk.NStmt (SIf (i, _, _, _, _))
              | Walk.NStmt (SLoop (i, _, _, _, _, _, _))
              | Walk.NStmt (SMatch (i, _, _, _))
              | Walk.NStmt (SDatatype (i, _, _, _, _, _))
              | Walk.NMatchCase (MatchCase (i, _, _, _, _)) ->
                  Some i
              | _ -> None
            in
            match span with
            | Some (i : Lexer.info) when i.row2 > i.row1 -> out @ [ range_json i.row1 i.row2 None ]
            | _ -> out)
          [] unit.stmts
  in
  let lines = Array.of_list (lines_of document.text) in
  let comment k = k < Array.length lines && String.length (String.trim lines.(k)) > 0 && (String.trim lines.(k)).[0] = '#' in
  let rec comments k out =
    if k >= Array.length lines then out
    else if comment k then
      let rec stop j = if comment j then stop (j + 1) else j in
      let e = stop k in
      comments e (if e - k >= 2 then out @ [ range_json (k + 1) e (Some "comment") ] else out)
    else comments (k + 1) out
  in
  let imports =
    match own_unit analysis document with
    | Some (unit, _) -> (
        let rows =
          List.filter_map (function SImport (i, _, _, _, _, _) -> Some i.row1 | _ -> None) unit.stmts
        in
        match rows with
        | first :: _ :: _ -> [ range_json first (List.fold_left max first rows) (Some "imports") ]
        | _ -> [])
    | None -> []
  in
  (state, Json.List (blocks @ comments 0 [] @ imports))

(* --- semantic tokens --- *)

(** The token types and modifiers semantic tokens name, in the order
    their numbers count. [string] *)
let token_types = [ "namespace"; "type"; "enumMember"; "function"; "parameter"; "variable"; "property" ]

let token_modifiers = [ "declaration"; "readonly"; "defaultLibrary" ]

(** Every name in a document with what it is -- a module, a type, a
    constructor, a function, a parameter, a variable or a field -- as
    LSP's semantic tokens, relative and in UTF-16.
    state -> document -> (state, Json.t) *)
let semantic_tokens state document =
  let state, analysis = analysis_of state document in
  (* Names and where they are written come from the text as it is now. *)
  match own_unit analysis document with
  | None -> (state, Json.Object [ ("data", Json.List []) ])
  | Some (unit, _) ->
      let found = resolve analysis.units unit in
      let index name = Option.value ~default:0 (List.find_index (fun t -> t = name) token_types) in
      let bit name = 1 lsl Option.value ~default:0 (List.find_index (fun t -> t = name) token_modifiers) in
      let of_meaning meaning =
        match meaning with
        | Bound (_, _, KFunction) -> Some (index "function", 0)
        | Bound (_, _, KParameter) -> Some (index "parameter", 0)
        | Bound (_, _, KValue) -> Some (index "variable", bit "readonly")
        | Bound (_, _, KVariable) -> Some (index "variable", 0)
        | Builtin -> Some (index "function", bit "defaultLibrary")
        | Module_of _ -> Some (index "namespace", 0)
        | Unknown -> None
      in
      let mine (i : Lexer.info) = (i.file = document.path || i.file = "") && i.row1 = i.row2 && i.col2 > i.col1 in
      let from_uses =
        List.filter_map
          (fun u ->
            if not (mine u.use_at) then None
            else Option.map (fun (t, m) -> (u.use_at, t, m)) (of_meaning u.use_meaning))
          found.uses
      in
      let from_bindings =
        List.filter_map
          (fun (_, (place : place), _, kind) ->
            if place.file <> document.path || not (mine place.span) then None
            else
              Option.map
                (fun (t, m) -> (place.span, t, m lor bit "declaration"))
                (of_meaning (Bound (place, 0, kind))))
          (bindings found)
      in
      let named name (i : Lexer.info) = name_span unit.tokens name i in
      let from_tree =
        Walk.fold_stmts
          (fun out node ->
            match node with
            | Walk.NExpr (EConstruct (i, _, name, _, _)) -> out @ [ (named name i, index "enumMember", 0) ]
            | Walk.NPattern (PConstructor (i, _, name, _, _, _)) -> out @ [ (named name i, index "enumMember", 0) ]
            | Walk.NConstructor (Constructor (i, name, _, _)) ->
                out @ [ (named name i, index "enumMember", bit "declaration") ]
            | Walk.NStmt (SDatatype (i, name, _, _, _, _)) -> out @ [ (named name i, index "type", bit "declaration") ]
            | Walk.NType (TCon (i, name, _, _)) when not (String.contains name '.') ->
                out @ [ (named name i, index "type", 0) ]
            | Walk.NExpr (EField (_, record, name, _)) ->
                let r = expr_info record in
                out @ [ (named name { r with row1 = r.row2; col1 = r.col2 }, index "property", 0) ]
            | _ -> out)
          [] unit.stmts
        |> List.filter (fun (i, _, _) -> mine i)
      in
      let all =
        List.sort_uniq
          (fun ((a : Lexer.info), _, _) ((b : Lexer.info), _, _) -> compare (a.row1, a.col1) (b.row1, b.col1))
          (from_bindings @ from_uses @ from_tree)
      in
      let _, _, _, data =
        List.fold_left
          (fun (last_row, last_col, last_end, data) ((i : Lexer.info), t, m) ->
            let line = line_at document.text i.row1 in
            let start = utf16_of_bytes line i.col1 and stop = utf16_of_bytes line i.col2 in
            if i.row1 = last_row && start < last_end then (last_row, last_col, last_end, data)
            else
              let delta_line = i.row1 - last_row in
              let delta_col = if delta_line = 0 then start - last_col else start in
              (i.row1, start, stop, data @ [ delta_line; delta_col; stop - start; t; m ]))
          (1, 0, 0, []) all
      in
      (state, Json.Object [ ("data", Json.List (List.map (fun n -> Json.Number (float_of_int n)) data)) ])

(* --- code actions --- *)

(** How many single-character edits make one name another.
    string -> string -> int *)
let distance a b =
  let m = String.length b in
  (* One row of the table per character of `a`, each made from the one
     before it. *)
  let next row i =
    let _, out =
      List.fold_left
        (fun (left, out) j ->
          let above = List.nth row j and diagonal = List.nth row (j - 1) in
          let cell = min (min (above + 1) (left + 1)) (diagonal + if a.[i - 1] = b.[j - 1] then 0 else 1) in
          (cell, out @ [ cell ]))
        (i, [ i ])
        (List.init m (fun j -> j + 1))
    in
    out
  in
  let last =
    List.fold_left next (List.init (m + 1) (fun j -> j)) (List.init (String.length a) (fun i -> i + 1))
  in
  List.nth last m

(** The fixes the error a document has offers, where the request's range
    meets it: the spelling Pyking has for one it no longer has (`+` for
    `++`, `^` for `**`) or for an operator's look-alike, the `use` line a
    construct needs, a name in scope for one that is not, and an
    annotation for the type the value has.
    state -> document -> Json.t -> (state, Json.t) *)
let code_actions state document range_ =
  let state, analysis = analysis_of state document in
  let r1, _ = row_col document.text (Json.member "start" range_) in
  let r2, _ = row_col document.text (Json.member "end" range_) in
  match analysis.problem with
  | Some p when p.at.file = document.path && p.at.row1 <= r2 && p.at.row2 >= r1 ->
      let action title edits =
        Json.Object
          [
            ("title", Json.String title);
            ("kind", Json.String "quickfix");
            ("isPreferred", Json.Bool true);
            ( "edit",
              Json.Object
                [ ("changes", Json.Object [ (document.uri, Json.List edits) ]) ] );
          ]
      in
      let edit (span : Lexer.info) text = Json.Object [ ("range", range document.text span); ("newText", Json.String text) ] in
      let contains_text needle = 
        let n = String.length needle and m = String.length p.message in
        let rec go i = i + n <= m && (String.sub p.message i n = needle || go (i + 1)) in
        go 0
      in
      let tokens = try Lexer.lexing document.path (Lexer.chars_of_string document.text) with _ -> [] in
      let inside (t : Lexer.info) = contains p.at t.row1 t.col1 && contains p.at t.row2 t.col2 in
      (* The operator of the expression the error is about: the one at
         its own depth, outside any parentheses within it. *)
      let operator wanted =
        let _, found =
          List.fold_left
            (fun (depth, found) token ->
              let i = Lexer.token_info token in
              if not (inside i) then (depth, found)
              else
                match token with
                | Lexer.TokLParen _ | Lexer.TokLBracket _ -> (depth + 1, found)
                | Lexer.TokRParen _ | Lexer.TokRBracket _ -> (depth - 1, found)
                | t when depth = 0 && found = None && wanted t -> (depth, Some i)
                | _ -> (depth, found))
            (0, None) tokens
        in
        found
      in
      (* A spelling Pyking no longer has, or an operator written where
         its look-alike belongs: the token the error is about, swapped
         for the one the message names. *)
      let swap wanted title text =
        match operator wanted with Some i -> [ action title [ edit i text ] ] | None -> []
      in
      let swaps =
        if contains_text "'++' is now written '+'" then
          swap (function Lexer.TokConcat _ -> true | _ -> false) "Change `++` to `+`" "+"
        else if contains_text "a power is written with '^'" then
          swap (function Lexer.TokStarStar _ -> true | _ -> false) "Change `**` to `^`" "^"
        else if contains_text "On Bools, write 'and'" then
          swap (function Lexer.TokAmp _ -> true | _ -> false) "Change `&` to `and`" "and"
        else if contains_text "On Bools, write 'or'" then
          swap (function Lexer.TokBar _ -> true | _ -> false) "Change `|` to `or`" "or"
        else if contains_text "On Bools, write '!='" then
          swap (function Lexer.TokXor _ -> true | _ -> false) "Change `xor` to `!=`" "!="
        else if contains_text "On Ints, write 'and'" then
          swap (function Lexer.TokAmpAmp _ -> true | _ -> false) "Change `&&` to `&`" "&"
        else if contains_text "On Ints, write 'or'" then
          swap (function Lexer.TokBarBar _ -> true | _ -> false) "Change `||` to `|`" "|"
        else if contains_text "On an Int, write 'not' or '~'" then
          swap (function Lexer.TokBang _ -> true | _ -> false) "Change `!` to `~`" "~"
        else if contains_text "On a Bool, write 'not' or '!'" then
          swap (function Lexer.TokTilde _ -> true | _ -> false) "Change `~` to `!`" "!"
        else []
      in
      (* A construct of a feature the module has not turned on: the `use`
         line that turns it on, above everything else. *)
      let features =
        List.concat_map
          (fun feature ->
            if contains_text (Printf.sprintf "needs 'use %s' at the top of this module" feature)
            then
              let top = Lexer.{ file = document.path; row1 = 1; col1 = 0; row2 = 1; col2 = 0 } in
              [ action (Printf.sprintf "Add 'use %s' at the top of the module" feature)
                  [ edit top (Printf.sprintf "use %s\n" feature) ] ]
            else [])
          Parser.features
      in
      let names =
        match String.index_opt p.message '\'' with
        | Some a when String.length p.message > 14 && String.sub p.message 0 14 = "unbound name '" -> (
            match String.index_from_opt p.message (a + 1) '\'' with
            | Some b when not (String.contains (String.sub p.message (a + 1) (b - a - 1)) '.') -> (
                let wrong = String.sub p.message (a + 1) (b - a - 1) in
                match own_unit analysis document with
                | None -> []
                | Some (unit, _) ->
                    let found = resolve analysis.units unit in
                    let candidates =
                      SMap.fold
                        (fun n meaning out ->
                          match meaning with
                          | Module_of _ | Unknown -> out
                          | _ ->
                              let d = distance wrong n in
                              let near = if String.length wrong <= 3 then 1 else 2 + (String.length wrong / 8) in
                              if n <> wrong && d <= near && not (String.contains n '.')
                              then (d, n) :: out
                              else out)
                        (names_at found p.at.row1 p.at.col1) []
                    in
                    List.map
                      (fun (_, n) -> action (Printf.sprintf "Change to '%s'" n) [ edit p.at n ])
                      (List.filteri (fun k _ -> k < 3) (List.sort compare candidates)))
            | _ -> [])
        | _ -> []
      in
      let annotation =
        let prefix = "this binding is annotated " in
        if String.length p.message > String.length prefix && String.sub p.message 0 (String.length prefix) = prefix then
          let rest = String.sub p.message (String.length prefix) (String.length p.message - String.length prefix) in
          let marker = ", but its value has type " in
          let rec find i =
            if i + String.length marker > String.length rest then None
            else if String.sub rest i (String.length marker) = marker then Some i
            else find (i + 1)
          in
          match find 0 with
          | Some k when p.at.row1 = p.at.row2 ->
              let actual = String.trim (String.sub rest (k + String.length marker) (String.length rest - k - String.length marker)) in
              let actual = String.concat " " (String.split_on_char '\n' actual) |> String.split_on_char ' ' |> List.filter (( <> ) "") |> String.concat " " in
              [ action (Printf.sprintf "Annotate it %s, the type of its value" actual) [ edit p.at actual ] ]
          | _ -> []
        else []
      in
      (state, Json.List (swaps @ features @ names @ annotation))
  | _ -> (state, Json.List [])

(* --- diagnostics --- *)

(** The import in a module that reaches the module a file belongs to,
    directly or through others. [Module.t] -> Module.t -> string ->
    stmt? *)
let import_reaching units (unit : Module.t) file =
  let owner =
    List.find_opt (fun (u : Module.t) -> u.path = file || u.declaration_path = Some file) units
  in
  let rec reaches seen name =
    match owner with
    | Some o when o.name = name -> true
    | _ -> (
        if List.mem name seen then false
        else
          match List.find_opt (fun (u : Module.t) -> u.name = name) units with
          | Some u -> List.exists (reaches (name :: seen)) u.imports
          | None -> false)
  in
  let stem = Filename.remove_extension (Filename.basename file) in
  List.find_opt
    (fun stmt ->
      match stmt with
      | SImport (_, module_, _, _, _, _) ->
          (owner <> None && reaches [] module_) || module_ = stem
          || module_ ^ "_external" = stem
      | _ -> false)
    unit.stmts

(** The diagnostics of a document: the first error the front end raised,
    placed in the document, or at the import that reaches the module it
    is in. state -> document -> analysis -> [Json.t] *)
let diagnostics state document analysis =
  let diagnostic range_ severity code message =
    Json.Object
      [ ("range", range_); ("severity", Json.Number (float_of_int severity)); ("source", Json.String "pyking");
        ("code", Json.String code); ("message", Json.String message) ]
  in
  let start = { Lexer.file = document.path; row1 = 1; col1 = 0; row2 = 1; col2 = 0 } in
  match (analysis.problem, analysis.internal) with
  | Some p, _ when p.at.file = document.path || p.at.file = "" ->
      [ diagnostic (range document.text p.at) 1 p.kind p.message ]
  | Some p, _ ->
      let own =
        match List.find_opt (fun (u : Module.t) -> u.path = document.path) analysis.units with
        | Some u -> Some u
        | None -> ( try Some (Module.read_file ~from:(sources state) document.path None) with _ -> None)
      in
      let at =
        match Option.bind own (fun u -> import_reaching analysis.units u p.at.file) with
        | Some stmt -> stmt_info stmt
        | None -> start
      in
      let where = Printf.sprintf "'%s' %d:%d" p.at.file p.at.row1 p.at.col1 in
      [ diagnostic (range document.text at) 1 p.kind (Printf.sprintf "%s: %s" where p.message) ]
  | None, Some internal ->
      [ diagnostic (range document.text start) 2 "internal" ("pyk lsp could not check this file: " ^ internal) ]
  | None, None -> []

(** A publishDiagnostics notification for a document. string -> int ->
    [Json.t] -> Json.t *)
let publish uri version items =
  Json.Object
    [ ("jsonrpc", Json.String "2.0"); ("method", Json.String "textDocument/publishDiagnostics");
      ( "params",
        Json.Object
          [ ("uri", Json.String uri); ("version", Json.Number (float_of_int version)); ("diagnostics", Json.List items) ] ) ]

let idle state =
  let due = List.filter (fun d -> d.due) state.documents in
  let state, messages =
    List.fold_left
      (fun (state, messages) document ->
        let state, analysis = analysis_of state document in
        let found = Json.to_string (Json.List (diagnostics state document analysis)) in
        (* Sent again only where it changed: every open document is
           checked when any changes, and most are as they were. *)
        if List.assoc_opt document.uri state.published = Some found then (state, messages)
        else
          ( { state with published = (document.uri, found) :: List.remove_assoc document.uri state.published },
            messages @ [ Json.to_string (publish document.uri document.version (diagnostics state document analysis)) ] ))
      (state, []) due
  in
  ({ state with documents = List.map (fun d -> { d with due = false }) state.documents }, messages)

(* --- the protocol --- *)

(** A response to a request. Json.t -> Json.t -> Json.t *)
let response id result = Json.Object [ ("jsonrpc", Json.String "2.0"); ("id", id); ("result", result) ]

(** An error response to a request. Json.t -> int -> string -> Json.t *)
let error_response id code message =
  Json.Object
    [ ("jsonrpc", Json.String "2.0"); ("id", id);
      ("error", Json.Object [ ("code", Json.Number (float_of_int code)); ("message", Json.String message) ]) ]

(** A message for the editor's log. string -> Json.t *)
let log_message message =
  Json.Object
    [ ("jsonrpc", Json.String "2.0"); ("method", Json.String "window/logMessage");
      ("params", Json.Object [ ("type", Json.Number 1.); ("message", Json.String message) ]) ]

(** Settings with what an editor sent applied: `libPath` and
    `diagnostics`, at the top or under `pyking`. settings -> Json.t ->
    settings *)
let configure settings value =
  let value = match Json.member "pyking" value with Json.Null -> value | inner -> inner in
  let lib_path =
    match Json.member "libPath" value with
    | Json.List items -> List.filter_map Json.to_string_option items
    | Json.String s -> [ s ]
    | _ -> settings.lib_path
  in
  let on_save =
    match Json.member "diagnostics" value with
    | Json.String "save" -> true
    | Json.String "change" -> false
    | _ -> settings.on_save
  in
  let inlay_hints =
    match Json.member "inlayHints" value with Json.Bool b -> b | _ -> settings.inlay_hints
  in
  { lib_path; on_save; inlay_hints }

(** What the server can do, for `initialize`. state -> Json.t *)
let capabilities state =
  Json.Object
    [
      ( "capabilities",
        Json.Object
          [
            ("positionEncoding", Json.String "utf-16");
            ( "textDocumentSync",
              Json.Object
                [ ("openClose", Json.Bool true); ("change", Json.Number 1.);
                  ("save", Json.Object [ ("includeText", Json.Bool false) ]) ] );
            ("hoverProvider", Json.Bool true);
            ("definitionProvider", Json.Bool true);
            ("documentSymbolProvider", Json.Bool true);
            ("completionProvider", Json.Object [ ("triggerCharacters", Json.List [ Json.String "." ]) ]);
            ( "signatureHelpProvider",
              Json.Object
                [
                  ("triggerCharacters", Json.List [ Json.String "("; Json.String "," ]);
                  ("retriggerCharacters", Json.List [ Json.String "=" ]);
                ] );
            ("referencesProvider", Json.Bool true);
            ("documentHighlightProvider", Json.Bool true);
            ("renameProvider", Json.Object [ ("prepareProvider", Json.Bool true) ]);
            ("inlayHintProvider", Json.Bool true);
            ("foldingRangeProvider", Json.Bool true);
            ( "semanticTokensProvider",
              Json.Object
                [
                  ( "legend",
                    Json.Object
                      [
                        ("tokenTypes", Json.List (List.map (fun t -> Json.String t) token_types));
                        ("tokenModifiers", Json.List (List.map (fun t -> Json.String t) token_modifiers));
                      ] );
                  ("full", Json.Bool true);
                ] );
            ("codeActionProvider", Json.Object [ ("codeActionKinds", Json.List [ Json.String "quickfix" ]) ]);
          ] );
      ("serverInfo", Json.Object [ ("name", Json.String "pyk lsp"); ("version", Json.String state.server_version) ]);
    ]

(** Every open document marked due to be checked again, as a change to
    one can change what another that imports it finds. state -> state *)
let all_due state = { state with documents = List.map (fun d -> { d with due = true }) state.documents }

(** A document's text with one change applied: the whole text, or a
    range replaced. string -> Json.t -> string *)
let apply_change text change =
  match Json.member "range" change with
  | Json.Null -> Option.value ~default:text (Json.to_string_option (Json.member "text" change))
  | r ->
      let replacement = Option.value ~default:"" (Json.to_string_option (Json.member "text" change)) in
      let r1, c1 = row_col text (Json.member "start" r) in
      let r2, c2 = row_col text (Json.member "end" r) in
      let a = offset_of text r1 c1 and b = offset_of text r2 c2 in
      String.sub text 0 a ^ replacement ^ String.sub text b (String.length text - b)

(** A notification: what it changes. state -> string -> Json.t -> state *)
let notify state method_ params =
  let uri = Option.value ~default:"" (Json.to_string_option (Json.member "uri" (Json.member "textDocument" params))) in
  let version = Option.value ~default:0 (Json.to_int_option (Json.member "version" (Json.member "textDocument" params))) in
  match method_ with
  | "initialized" | "$/cancelRequest" | "$/setTrace" -> state
  | "workspace/didChangeConfiguration" ->
      all_due { state with settings = configure state.settings (Json.member "settings" params) }
  | "textDocument/didOpen" ->
      let text = Option.value ~default:"" (Json.to_string_option (Json.member "text" (Json.member "textDocument" params))) in
      let document = { uri; path = path_of_uri uri; text; version; due = true } in
      let others = List.filter (fun d -> d.uri <> uri) state.documents in
      let state = { state with documents = others @ [ document ]; analyses = List.remove_assoc uri state.analyses } in
      if state.settings.on_save then state else all_due state
  | "textDocument/didChange" -> (
      match List.find_opt (fun d -> d.uri = uri) state.documents with
      | None -> state
      | Some d ->
          let text = List.fold_left apply_change d.text (Json.to_list (Json.member "contentChanges" params)) in
          let changed = { d with text; version = (if version = 0 then d.version + 1 else version) } in
          let state = { state with documents = List.map (fun x -> if x.uri = uri then changed else x) state.documents } in
          (* Every analysis may read this text, through an import. *)
          let state = { state with analyses = List.map (fun (u, a) -> (u, { a with checked_version = -1 })) state.analyses } in
          if state.settings.on_save then state else all_due state)
  | "textDocument/didSave" ->
      let state = { state with analyses = List.map (fun (u, a) -> (u, { a with checked_version = -1 })) state.analyses } in
      all_due state
  | "textDocument/didClose" ->
      {
        state with
        documents = List.filter (fun d -> d.uri <> uri) state.documents;
        published = List.remove_assoc uri state.published;
        analyses =
          List.map (fun (u, a) -> (u, { a with checked_version = -1 })) (List.remove_assoc uri state.analyses);
      }
  | _ -> state

(** A request: the state after it and its result, or an error code and
    message. state -> string -> Json.t -> (state, (Json.t, (int, string))
    result) *)
let request state method_ params =
  let document () =
    let uri = Option.value ~default:"" (Json.to_string_option (Json.member "uri" (Json.member "textDocument" params))) in
    List.find_opt (fun d -> d.uri = uri) state.documents
  in
  let on_document answer =
    match document () with
    | Some d ->
        let state, result = answer state d in
        (state, Ok result)
    | None -> (state, Ok Json.Null)
  in
  match method_ with
  | "shutdown" -> ({ state with phase = Shut_down }, Ok Json.Null)
  | "textDocument/hover" -> on_document (fun s d -> hover s d (Json.member "position" params))
  | "textDocument/definition" -> on_document (fun s d -> definition s d (Json.member "position" params))
  | "textDocument/documentSymbol" -> on_document document_symbols
  | "textDocument/completion" -> on_document (fun s d -> completion s d (Json.member "position" params))
  | "textDocument/signatureHelp" -> on_document (fun s d -> signature_help s d (Json.member "position" params))
  | "textDocument/references" ->
      let declaration =
        match Json.member "includeDeclaration" (Json.member "context" params) with Json.Bool b -> b | _ -> true
      in
      on_document (fun s d -> references s d (Json.member "position" params) declaration)
  | "textDocument/documentHighlight" -> on_document (fun s d -> highlights s d (Json.member "position" params))
  | "textDocument/prepareRename" | "textDocument/rename" -> (
      match document () with
      | None -> (state, Ok Json.Null)
      | Some d ->
          if method_ = "textDocument/prepareRename" then prepare_rename state d (Json.member "position" params)
          else
            rename state d (Json.member "position" params)
              (Option.value ~default:"" (Json.to_string_option (Json.member "newName" params))))
  | "textDocument/inlayHint" -> on_document (fun s d -> inlay_hints s d (Json.member "range" params))
  | "textDocument/foldingRange" -> on_document folding_ranges
  | "textDocument/semanticTokens/full" -> on_document semantic_tokens
  | "textDocument/codeAction" -> on_document (fun s d -> code_actions s d (Json.member "range" params))
  | _ -> (state, Error (-32601, "method not found: " ^ method_))

let handle state text =
  match Json.parse text with
  | exception Json.Parse_error message ->
      (state, [ Json.to_string (error_response Json.Null (-32700) ("parse error: " ^ message)) ])
  | message -> (
      let id = Json.member "id" message in
      let method_ = Option.value ~default:"" (Json.to_string_option (Json.member "method" message)) in
      let params = Json.member "params" message in
      let is_request = id <> Json.Null && method_ <> "" in
      let reply json = Json.to_string json in
      match state.phase with
      | Exited _ -> (state, [])
      | _ when method_ = "exit" -> ({ state with phase = Exited (if state.phase = Shut_down then 0 else 1) }, [])
      | _ when method_ = "" -> (state, [])
      | Fresh ->
          if method_ = "initialize" then
            let settings = configure state.settings (Json.member "initializationOptions" params) in
            ({ state with phase = Running; settings }, [ reply (response id (capabilities state)) ])
          else if is_request then (state, [ reply (error_response id (-32002) "the server is not initialized") ])
          else (state, [])
      | Shut_down ->
          if is_request then (state, [ reply (error_response id (-32600) "the server has been shut down") ])
          else (state, [])
      | Running ->
          if method_ = "initialize" then
            (state, [ reply (error_response id (-32600) "initialize was sent twice") ])
          else if is_request then
            match request state method_ params with
            | state, Ok result -> (state, [ reply (response id result) ])
            | state, Error (code, why) -> (state, [ reply (error_response id code why) ])
            | exception error ->
                let why = Printexc.to_string error in
                (state, [ reply (error_response id (-32603) ("internal error: " ^ why)); reply (log_message ("pyk lsp: " ^ method_ ^ ": " ^ why)) ])
          else
            match notify state method_ params with
            | state -> (state, [])
            | exception error ->
                (state, [ reply (log_message ("pyk lsp: " ^ method_ ^ ": " ^ Printexc.to_string error)) ]))
